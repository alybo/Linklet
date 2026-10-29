import AppKit
import WebKit

/// An isolated-world renderer follows WebKit's real DOM selection inside its own
/// frame. It never replaces page text, sends requests or intercepts mouse input.
@MainActor
final class PageFindHighlighter: NSObject, WKScriptMessageHandler {
    static let shared = PageFindHighlighter()
    static let world = WKContentWorld.world(name: "Linklet.FindHighlight")
    private static let handlerName = "linkletFindHighlight"
    private let installedControllers = NSHashTable<WKUserContentController>.weakObjects()
    private let owners = NSMapTable<WKWebView, PageFindController>.weakToWeakObjects()
    private var frames: [ObjectIdentifier: [String: WKFrameInfo]] = [:]
    private var revisions: [ObjectIdentifier: UUID] = [:]
    private var activeFrames: [ObjectIdentifier: String] = [:]
    private var observers: [NSObjectProtocol] = []

    override private init() {
        super.init()
        for name in [NSColor.systemColorsDidChangeNotification, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            let center = name == NSColor.systemColorsDidChangeNotification ? NotificationCenter.default : NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateAppearance() }
            })
        }
    }

    func install(in content: WKUserContentController) {
        guard !installedControllers.contains(content) else { return }
        installedControllers.add(content)
        content.add(self, contentWorld: Self.world, name: Self.handlerName)
        content.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                          forMainFrameOnly: false, in: Self.world))
    }

    func attach(_ view: WKWebView, owner: PageFindController) {
        owners.setObject(owner, forKey: view)
    }

    func hasFrames(in view: WKWebView) -> Bool {
        frames[ObjectIdentifier(view)]?.isEmpty == false
    }

    func selectedFrame(in view: WKWebView) -> WKFrameInfo? {
        let id = ObjectIdentifier(view)
        guard let key = activeFrames[id] else { return nil }
        return frames[id]?[key]
    }

    func prepare(_ view: WKWebView, preservingHighlight: Bool) {
        revisions[ObjectIdentifier(view)] = UUID()
        for frame in frames[ObjectIdentifier(view)]?.values ?? Dictionary<String, WKFrameInfo>().values {
            call("globalThis.__linkletFindHighlight?.prepare(preserve)", arguments: ["preserve": preservingHighlight], in: view, frame: frame)
        }
    }

    func detach(_ view: WKWebView) {
        clear(view)
        owners.removeObject(forKey: view)
        frames.removeValue(forKey: ObjectIdentifier(view))
        revisions.removeValue(forKey: ObjectIdentifier(view))
    }

    func clear(_ view: WKWebView) {
        let id = ObjectIdentifier(view)
        revisions[id] = UUID()
        activeFrames.removeValue(forKey: id)
        for frame in frames[id]?.values ?? Dictionary<String, WKFrameInfo>().values {
            call("globalThis.__linkletFindHighlight?.hide()", in: view, frame: frame)
        }
    }

    func render(in view: WKWebView, query: String, animate: Bool) {
        guard !query.isEmpty, let knownFrames = frames[ObjectIdentifier(view)], !knownFrames.isEmpty else { return }
        let id = ObjectIdentifier(view)
        let revision = UUID()
        revisions[id] = revision
        var remaining = knownFrames.count
        var candidates: [(String, WKFrameInfo, Double)] = []
        for (key, frame) in knownFrames {
            view.callAsyncJavaScript("return globalThis.__linkletFindHighlight?.candidate(query) ?? null",
                                     arguments: ["query": query], in: frame, in: Self.world) { [weak self, weak view] result in
                guard let self, let view, revisions[id] == revision else { return }
                if case let .success(value) = result, let value = value as? [String: Any],
                   let stamp = value["stamp"] as? Double {
                    candidates.append((key, frame, stamp))
                } else if case .failure = result {
                    frames[id]?.removeValue(forKey: key)
                }
                remaining -= 1
                guard remaining == 0 else { return }
                let winner = candidates.max { $0.2 < $1.2 }
                activeFrames[id] = winner?.0
                if winner != nil { owners.object(forKey: view)?.hideNativeFindPaint(in: view) }
                for (frameKey, info) in knownFrames {
                    if frameKey == winner?.0 {
                        call("globalThis.__linkletFindHighlight?.show(query, color, animate, reduceMotion)",
                             arguments: ["query": query, "color": accentColor(in: view), "animate": animate,
                                         "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion],
                             in: view, frame: info)
                    } else {
                        call("globalThis.__linkletFindHighlight?.hide()", in: view, frame: info)
                    }
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, let view = message.webView,
              let body = message.body as? [String: String], let frameID = body["frame"] else { return }
        let id = ObjectIdentifier(view)
        if body["event"] == "gone" { frames[id]?.removeValue(forKey: frameID); return }
        guard body["event"] == "ready" else { return }
        // Frame-local renderers avoid cross-origin coordinate translation. Dead
        // frame entries are removed when their next evaluation fails.
        frames[id, default: [:]][frameID] = message.frameInfo
        if let owner = owners.object(forKey: view), owner.usesNativeMatchCounts, owner.isPresented, !owner.isSearching, owner.matchCount != 0 {
            render(in: view, query: owner.query, animate: false)
        }
    }

    private func updateAppearance() {
        for view in owners.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) {
            updateAppearance(in: view)
        }
    }

    func updateAppearance(in view: WKWebView) {
        guard let frame = selectedFrame(in: view) else { return }
        call("globalThis.__linkletFindHighlight?.appearance(color, reduceMotion)",
             arguments: ["color": accentColor(in: view), "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion],
             in: view, frame: frame)
    }

    private func accentColor(in view: WKWebView) -> String {
        var color = NSColor.controlAccentColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        }
        return "rgb(\(Int((color.redComponent * 255).rounded())), \(Int((color.greenComponent * 255).rounded())), \(Int((color.blueComponent * 255).rounded())))"
    }

    private func call(_ body: String, arguments: [String: Any] = [:], in view: WKWebView, frame: WKFrameInfo) {
        view.callAsyncJavaScript(body, arguments: arguments, in: frame, in: Self.world, completionHandler: nil)
    }

    static let script = #"""
    (() => {
      if (globalThis.__linkletFindHighlight) return;
      // Bookkeeping identity, also available on ordinary non-secure HTTP pages.
      const frame = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
      let stamp = performance.timeOrigin + performance.now();
      let host, shadow, range, startHandle, endHandle, selectionSheet, observer, resizeObserver;
      let segments = [], query = '', color = '', reduced = false, queued = false, previous = null;
      let lastAnimation = false, active = false, pending = false, observing = false;
      const selection = () => {
        const s = getSelection();
        if (!s || s.isCollapsed || !s.rangeCount) return null;
        const r = s.getRangeAt(0);
        return r.startContainer.isConnected && r.endContainer.isConnected ? r : null;
      };
      const equals = (a,b) => a.toLocaleLowerCase() === b.toLocaleLowerCase();
      const valid = r => r && !r.collapsed && equals(r.toString(), query);
      const create = (styles, parent) => {
        const node = document.createElement('span');
        Object.assign(node.style, {position:'absolute', display:'block', margin:'0', padding:'0', border:'0', pointerEvents:'none', boxSizing:'border-box', ...styles});
        parent.append(node);
        return node;
      };
      function setup() {
        if (host?.isConnected) return;
        host = document.createElement('div');
        host.setAttribute('aria-hidden','true');
        host.style.cssText = 'all:initial;position:fixed;inset:0;display:block;pointer-events:none;z-index:2147483647;overflow:visible;';
        shadow = host.attachShadow({mode:'closed'});
        startHandle = create({},shadow);
        endHandle = create({},shadow);
        startHandle.stem = create({}, startHandle);
        startHandle.dot = create({borderRadius:'50%'}, startHandle);
        endHandle.stem = create({}, endHandle);
        endHandle.dot = create({borderRadius:'50%'}, endHandle);
        document.documentElement.append(host);
        selectionSheet = new CSSStyleSheet();
        // Suppress only the current DOM selection's default paint while our
        // presentation is active; never change the page's text or its selection.
        selectionSheet.replaceSync('::selection { background-color: transparent !important; color: inherit !important; text-shadow: none !important; }');
      }
      function suppressSelection(enabled) {
        if (!selectionSheet) return;
        const sheets = document.adoptedStyleSheets;
        const present = sheets.includes(selectionSheet);
        if (enabled && !present) document.adoptedStyleSheets = [...sheets, selectionSheet];
        if (!enabled && present) document.adoptedStyleSheets = sheets.filter(s => s !== selectionSheet);
      }
      function hide() {
        active = false; pending = false; range = null; previous = null; query = '';
        if (host) host.style.display = 'none';
        suppressSelection(false);
        observer?.disconnect(); resizeObserver?.disconnect();
        observing = false;
      }
      function schedule() {
        if (!active || queued) return;
        queued = true;
        requestAnimationFrame(() => { queued = false; draw(false); });
      }
      function rectsFor(r) {
        const result = [];
        for (const rect of r.getClientRects()) {
          if (rect.width < .1 || rect.height < .1) continue;
          const sameLine = result.find(a => Math.abs(a.y-rect.y)<1.5 && Math.abs(a.height-rect.height)<2 && rect.x<=a.x+a.width+1 && rect.x+rect.width>=a.x-1);
          if (sameLine) {
            const right = Math.max(sameLine.x+sameLine.width,rect.right);
            sameLine.x = Math.min(sameLine.x,rect.x); sameLine.width = right-sameLine.x;
          } else result.push({x:rect.x,y:rect.y,width:rect.width,height:rect.height});
        }
        return result;
      }
      function caret(r, atStart, fallback) {
        const c = r.cloneRange(); c.collapse(atStart);
        const rect = c.getClientRects()[0];
        if (rect && rect.height > 0) return {x:rect.x,y:rect.y,height:rect.height};
        const element = (atStart ? r.startContainer : r.endContainer).parentElement;
        const rtl = element && getComputedStyle(element).direction === 'rtl';
        return {x:atStart !== rtl ? fallback.x : fallback.x+fallback.width,y:fallback.y,height:fallback.height};
      }
      function draw(wantsAnimation) {
        if (!active || !valid(range)) { hide(); return; }
        const rects = rectsFor(range);
        if (!rects.length) { host.style.display='none'; return; }
        host.style.display='block';
        const start = caret(range,true,rects[0]);
        const end = caret(range,false,rects[rects.length-1]);
        if (previous && previous.query===query && previous.color===color && previous.reduced===reduced &&
            previous.start.x===start.x && previous.start.y===start.y && previous.end.x===end.x && previous.end.y===end.y &&
            JSON.stringify(previous.rects)===JSON.stringify(rects)) return;
        const animate = !!(wantsAnimation && !reduced && !matchMedia('(prefers-reduced-motion: reduce)').matches && previous &&
          (query.toLocaleLowerCase().startsWith(previous.query.toLocaleLowerCase()) || previous.query.toLocaleLowerCase().startsWith(query.toLocaleLowerCase())) &&
          Math.abs(start.x-previous.start.x)<2 && Math.abs(start.y-previous.start.y)<2);
        const transition = animate ? 'transform 170ms cubic-bezier(.2,.8,.2,1), width 170ms cubic-bezier(.2,.8,.2,1), height 170ms cubic-bezier(.2,.8,.2,1)' : 'none';
        while (segments.length < rects.length) segments.push(create({borderRadius:'1px',zIndex:'0'},shadow));
        segments.forEach((node,index) => {
          const rect = rects[index]; node.style.display = rect ? 'block' : 'none';
          if (!rect) return;
          node.style.transition = transition;
          node.style.transform = `translate(${rect.x}px,${rect.y}px)`;
          node.style.width = `${rect.width}px`; node.style.height = `${rect.height}px`;
          node.style.backgroundColor = color; node.style.opacity = '.24';
        });
        [startHandle,endHandle].forEach((node,index) => {
          const p = index ? end : start;
          const radius = Math.min(5.5,Math.max(3,p.height*.16));
          const stroke = Math.min(2.5,Math.max(1.5,p.height*.075));
          node.style.transition = transition;
          node.style.transform = `translate(${p.x}px,${p.y}px)`;
          node.style.zIndex = '1';
          Object.assign(node.stem.style,{left:`${-stroke/2}px`,top:'0',width:`${stroke}px`,height:`${p.height}px`,backgroundColor:color});
          Object.assign(node.dot.style,{left:`${-radius}px`,top:`${index ? p.height : -2*radius}px`,width:`${radius*2}px`,height:`${radius*2}px`,backgroundColor:color});
        });
        lastAnimation = animate;
        previous = {query,start,end,color,reduced,rects};
      }
      document.addEventListener('selectionchange', () => {
        stamp = performance.timeOrigin + performance.now();
        if (!active || pending) return;
        const next = selection();
        if (!next || !equals(next.toString(),query)) {
          hide(); return;
        }
        if (range && range.startContainer===next.startContainer && range.startOffset===next.startOffset &&
            range.endContainer===next.endContainer && range.endOffset===next.endOffset) return;
        range = next.cloneRange(); schedule();
      });
      addEventListener('scroll',schedule,{passive:true,capture:true});
      addEventListener('resize',schedule,{passive:true});
      visualViewport?.addEventListener('resize',schedule,{passive:true});
      visualViewport?.addEventListener('scroll',schedule,{passive:true});
      globalThis.__linkletFindHighlight = {
        candidate(value) { const r=selection(); return r && equals(r.toString(),value) ? {stamp} : null; },
        prepare(preserve) { if (!preserve) hide(); pending=true; },
        show(value, accent, animate, reduceMotion) {
          const r=selection(); if (!r || !equals(r.toString(),value)) { hide(); return; }
          setup(); query=value; color=accent; reduced=reduceMotion; range=r.cloneRange(); active=true; pending=false;
          suppressSelection(true);
          draw(animate);
          if (!observing) {
            observing = true;
            observer = new MutationObserver(schedule);
            if (document.body) observer.observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:['class','style','hidden']});
            let initialSize = true;
            resizeObserver = new ResizeObserver(() => { if(initialSize) {initialSize=false;return;} schedule(); });
            resizeObserver.observe(document.documentElement);
            if (document.fonts?.status !== 'loaded') document.fonts?.ready.then(schedule);
          }
        },
        appearance(accent, reduceMotion) { color=accent; reduced=reduceMotion; if(active) draw(false); },
        hide,
        diagnostics() {
          return {active,query,color,reduced,animated:lastAnimation,rects:range ? rectsFor(range) : [],
            start:previous?.start ?? null,end:previous?.end ?? null,display:host?.style.display ?? 'none',
            endTransform:endHandle?.style.transform ?? '',endTransition:endHandle?.style.transition ?? '',
            selected:String(getSelection()),pointerEvents:host?.style.pointerEvents ?? '',ariaHidden:host?.getAttribute('aria-hidden') ?? ''};
        }
      };
      const announce = () => webkit.messageHandlers.linkletFindHighlight.postMessage({event:'ready',frame});
      addEventListener('pageshow',announce);
      addEventListener('pagehide',() => { hide(); webkit.messageHandlers.linkletFindHighlight.postMessage({event:'gone',frame}); });
      announce();
    })();
    """#
}
