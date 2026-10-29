import AppKit
import WebKit

/// HTML results own their Ranges instead of borrowing the page's user selection.
/// Inaccessible documents retain the native WebKit search path.
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

    struct Result { let count: Int; let index: Int; let limited: Bool }

    override private init() {
        super.init()
        for name in [NSColor.systemColorsDidChangeNotification, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            let center = name == NSColor.systemColorsDidChangeNotification ? NotificationCenter.default : NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    for view in self.owners.keyEnumerator().allObjects.compactMap({ $0 as? WKWebView }) { self.updateAppearance(in: view) }
                }
            })
        }
    }

    func install(in content: WKUserContentController) {
        guard !installedControllers.contains(content) else { return }
        installedControllers.add(content)
        content.add(self, contentWorld: Self.world, name: Self.handlerName)
        content.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world))
    }

    func attach(_ view: WKWebView, owner: PageFindController) { owners.setObject(owner, forKey: view) }
    func hasFrames(in view: WKWebView) -> Bool { frames[ObjectIdentifier(view)]?.isEmpty == false }
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
        let id = ObjectIdentifier(view)
        owners.removeObject(forKey: view); frames.removeValue(forKey: id); revisions.removeValue(forKey: id)
    }

    func clear(_ view: WKWebView) {
        let id = ObjectIdentifier(view)
        revisions[id] = UUID(); activeFrames.removeValue(forKey: id)
        for frame in frames[id]?.values ?? Dictionary<String, WKFrameInfo>().values { call("globalThis.__linkletFindHighlight?.hide()", in: view, frame: frame) }
    }

    /// Every frame indexes only its own rendered composed tree. Keep the main
    /// document first, followed by its frames, as in the existing WebKit results.
    func search(in view: WKWebView, query: String, step: Int, animate: Bool, preserve: Bool,
                completion: @escaping (Result?) -> Void) {
        let id = ObjectIdentifier(view)
        guard let known = frames[id], !known.isEmpty else { completion(nil); return }
        let ordered = known.sorted { a, b in
            if a.value.isMainFrame != b.value.isMainFrame { return a.value.isMainFrame }
            return a.key < b.key
        }
        let revision = UUID(); revisions[id] = revision
        let oldFrame = activeFrames[id]
        var remaining = ordered.count
        var results: [String: (Int, Int?)] = [:]
        var supported = false
        for (key, frame) in ordered {
            view.callAsyncJavaScript("return globalThis.__linkletFindHighlight?.matches(query) ?? null", arguments: ["query": query], in: frame, in: Self.world) { [weak self, weak view] response in
                guard let self, let view, revisions[id] == revision else { return }
                if case let .success(value) = response, let data = value as? [String: Any], data["supported"] as? Bool == true {
                    supported = true
                    results[key] = (data["count"] as? Int ?? 0, data["preferred"] as? Int)
                } else if case .failure = response { frames[id]?.removeValue(forKey: key) }
                remaining -= 1
                guard remaining == 0 else { return }
                guard supported else { completion(nil); return }
                let total = ordered.reduce(0) { $0 + (results[$1.key]?.0 ?? 0) }
                guard total > 0 else { clear(view); completion(Result(count: 0, index: 0, limited: false)); return }
                var selected = 0, offset = 0
                if preserve, let oldFrame {
                    for (key, _) in ordered {
                        if key == oldFrame, let preferred = results[key]?.1 { selected = offset + preferred; break }
                        offset += results[key]?.0 ?? 0
                    }
                }
                selected = (selected + step % total + total) % total
                offset = 0
                for (key, info) in ordered {
                    let count = results[key]?.0 ?? 0
                    if selected >= offset && selected < offset + count {
                        activeFrames[id] = key
                        call("globalThis.__linkletFindHighlight?.showMatch(index, color, animate, reduceMotion)",
                             arguments: ["index": selected-offset, "color": accentColor(in: view), "animate": animate,
                                         "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion], in: view, frame: info)
                    } else { call("globalThis.__linkletFindHighlight?.hide()", in: view, frame: info) }
                    offset += count
                }
                completion(Result(count: min(total, 10_000), index: selected, limited: total >= 10_000))
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, let view = message.webView, let body = message.body as? [String: String], let frameID = body["frame"] else { return }
        let id = ObjectIdentifier(view)
        if body["event"] == "gone" { frames[id]?.removeValue(forKey: frameID); return }
        guard body["event"] == "ready" else { return }
        frames[id, default: [:]][frameID] = message.frameInfo
        if let owner = owners.object(forKey: view), owner.isPresented, !owner.isSearching { owner.refreshHTMLResults() }
    }

    func updateAppearance(in view: WKWebView) {
        guard let frame = selectedFrame(in: view) else { return }
        call("globalThis.__linkletFindHighlight?.appearance(color, reduceMotion)",
             arguments: ["color": accentColor(in: view), "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion], in: view, frame: frame)
    }

    private func accentColor(in view: WKWebView) -> String {
        var color = NSColor.controlAccentColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue }
        return "rgb(\(Int((color.redComponent*255).rounded())), \(Int((color.greenComponent*255).rounded())), \(Int((color.blueComponent*255).rounded())))"
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
      let host, shadow, range, startHandle, endHandle, observer, resizeObserver;
      let segments = [], query = '', color = '', reduced = false, queued = false, previous = null;
      let lastAnimation = false, active = false, pending = false, observing = false;
      let hits = [], searchQuery = '', anchor = null, raf = 0, dirty = false, selectionChanges = 0, searchRoots = [];
      const equals = (a,b) => a.toLocaleLowerCase() === b.toLocaleLowerCase();
      const valid = r => r && !r.collapsed && r.startContainer.nodeType===3 && r.endContainer.nodeType===3 && r.startContainer.isConnected && r.endContainer.isConnected && equals(r.toString().replace(/\s+/gu,' '), query.replace(/\s+/gu,' '));
      const parentElement = node => node.nodeType===1 ? node : node.parentElement;
      const composedParent = element => element?.assignedSlot ?? element?.parentElement ?? element?.getRootNode()?.host ?? null;
      function stableElement(node) {
        const path=[];
        for(let e=parentElement(node);e;e=composedParent(e)) if(e.id) path.unshift(e.id);
        return path.length ? {id:path.join('/')} : null;
      }
      function collect(value) {
        const found = [], visited = new Set();searchRoots=[document.documentElement];
        if (!value) return found;
        const expression = new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g,'\\$&').replace(/\s+/gu,'\\s+'),'giu');
        let text='', parts=[], root=null;
        function flush() {
          if(text && parts.length) {
            expression.lastIndex=0;
            let match;
            while(found.length<10001 && (match=expression.exec(text))) {
              const from=match.index, to=from+match[0].length;
              const at = offset => { let low=0,high=parts.length;while(low<high){const mid=(low+high)>>1;if(parts[mid].to<=offset)low=mid+1;else high=mid;}return parts[low]; };
              const a=at(from), b=at(to-1);
              if(a && b) {
                const r=document.createRange();
                r.setStart(a.node,a.space ? a.start : a.start+from-a.from);
                r.setEnd(b.node,b.space ? b.end : b.start+to-b.from);
                found.push(r);
              }
            }
          }
          text='';parts=[];root=null;
        }
        function append(node) {
          if(root && root!==node.getRootNode()) flush();
          root=node.getRootNode();
          const raw=node.data;
          const pattern=/\s+|\S+/gu;
          let m;
          while((m=pattern.exec(raw))) {
            const space=/^\s/u.test(m[0]);
            if(space && text.endsWith(' ')) continue;
            const content=space ? ' ' : m[0];
            const from=text.length; text+=content;
            parts.push({node,from,to:text.length,start:m.index,end:m.index+m[0].length,space});
          }
        }
        function visit(node) {
          if(visited.has(node) || found.length>=10001) return;
          visited.add(node);
          if(node.nodeType===3) { append(node);return; }
          if(node.nodeType!==1 && node.nodeType!==11) return;
          if(node===host) return;
          let block=false;
          if(node.nodeType===1) {
            if(/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|INPUT|TEXTAREA|SELECT|OPTION|IFRAME|FRAME|CANVAS|SVG)$/u.test(node.tagName)) return;
            const style=getComputedStyle(node);
            if(style.display==='none' || style.visibility==='hidden' || style.visibility==='collapse' || style.contentVisibility==='hidden') return;
            block=!(style.display.startsWith('inline') || style.display==='contents');
            if(block) flush();
            if(node.shadowRoot) { searchRoots.push(node.shadowRoot);flush();visit(node.shadowRoot);flush(); }
            else if(node.tagName==='SLOT') {
              const assigned=node.assignedNodes({flatten:true});
              for(const child of assigned.length ? assigned : node.childNodes) visit(child);
            } else for(const child of node.childNodes) visit(child);
            if(block) flush();
          } else for(const child of node.childNodes) visit(child);
        }
        visit(document.body ?? document.documentElement);flush();
        return found;
      }
      function watch() {
        if(!observer) return;
        observer.disconnect();
        for(const root of searchRoots) if(root.isConnected) observer.observe(root,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:['class','style','hidden']});
      }
      function remember(r,index) {
        const stable=stableElement(r.startContainer);
        const start=r.startContainer, end=r.endContainer;
        anchor={container:parentElement(r.commonAncestorContainer),stable:stable?.id ?? null,index,
          before:start.nodeType===3 ? start.data.slice(Math.max(0,r.startOffset-28),r.startOffset) : '',
          after:end.nodeType===3 ? end.data.slice(r.endOffset,r.endOffset+28) : ''};
      }
      function preferred(list) {
        if(range) {
          const exact=list.findIndex(r=>r.startContainer===range.startContainer && r.startOffset===range.startOffset);
          if(exact>=0) return exact;
        }
        if(!anchor) return -1;
        const candidates=[];
        list.forEach((r,index)=>{
          if(anchor.stable && stableElement(r.startContainer)?.id===anchor.stable) candidates.push(index);
          else if(!anchor.stable && anchor.container?.isConnected && anchor.container.contains(r.startContainer)) candidates.push(index);
        });
        if(candidates.length===1) return candidates[0];
        const context=list.map((r,index)=>({r,index})).filter(({r})=>
          (!anchor.before || (r.startContainer.nodeType===3 && r.startContainer.data.slice(Math.max(0,r.startOffset-28),r.startOffset)===anchor.before)) &&
          (!anchor.after || (r.endContainer.nodeType===3 && r.endContainer.data.slice(r.endOffset,r.endOffset+28)===anchor.after)));
        if((anchor.before || anchor.after) && context.length===1 && (!anchor.stable || candidates.includes(context[0].index))) return context[0].index;
        return candidates.length ? candidates.reduce((a,b)=>Math.abs(a-anchor.index)<=Math.abs(b-anchor.index) ? a : b) : -1;
      }
      function repair() {
        if(!query || !anchor) return false;
        const list=collect(query), index=preferred(list);
        if(index<0) return false;
        hits=list;range=list[index].cloneRange();remember(range,index);watch();return true;
      }
      function conceal() {
        if(host && host.style.display!=='none') host.style.display='none';
        previous=null;
      }
      function track() {
        raf=0;
        if(!active) return;
        if(document.visibilityState!=='hidden') {
          if(!valid(range) && dirty) repair();
          dirty=false;
          draw(false);
        }
        raf=requestAnimationFrame(track);
      }
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
        host.style.cssText = 'all:initial;position:fixed!important;inset:0!important;margin:0!important;padding:0!important;border:0!important;display:block;pointer-events:none!important;z-index:2147483647;overflow:clip;width:100vw!important;height:100vh!important;';
        shadow = host.attachShadow({mode:'closed'});
        startHandle = create({},shadow);
        endHandle = create({},shadow);
        startHandle.stem = create({}, startHandle);
        startHandle.dot = create({borderRadius:'50%'}, startHandle);
        endHandle.stem = create({}, endHandle);
        endHandle.dot = create({borderRadius:'50%'}, endHandle);
        document.documentElement.append(host);
        if(typeof host.showPopover==='function') { host.popover='manual';host.showPopover(); }
      }
      function hide() {
        active = false; pending = false; range = null; previous = null; query = '';
        if (host) host.style.display = 'none';
        hits=[];searchQuery='';anchor=null;
        if(raf) cancelAnimationFrame(raf);raf=0;
        if(host?.matches(':popover-open')) host.hidePopover();
        observer?.disconnect(); resizeObserver?.disconnect();
        observing = false;
      }
      function schedule() {
        if (!active || queued) return;
        queued = true;
        requestAnimationFrame(() => { queued=false;dirty=true; });
      }
      function clipBounds(r) {
        let left=0,top=0,right=innerWidth,bottom=innerHeight;
        for(let e=parentElement(r.startContainer);e;e=composedParent(e)) {
          if(e===document.documentElement || e===document.body) continue;
          const style=getComputedStyle(e);
          const clipX=style.overflowX!=='visible',clipY=style.overflowY!=='visible';
          if(!clipX && !clipY) continue;
          const b=e.getBoundingClientRect(),sx=e.offsetWidth ? b.width/e.offsetWidth : 1,sy=e.offsetHeight ? b.height/e.offsetHeight : 1;
          if(clipX) {left=Math.max(left,b.left+e.clientLeft*sx);right=Math.min(right,b.left+(e.clientLeft+e.clientWidth)*sx);}
          if(clipY) {top=Math.max(top,b.top+e.clientTop*sy);bottom=Math.min(bottom,b.top+(e.clientTop+e.clientHeight)*sy);}
        }
        return {left,top,right,bottom};
      }
      function rectsFor(r) {
        const result = [], clip=clipBounds(r);
        for (const raw of r.getClientRects()) {
          const x=Math.max(raw.x,clip.left),y=Math.max(raw.y,clip.top);
          const rect={x,y,right:Math.min(raw.right,clip.right),bottom:Math.min(raw.bottom,clip.bottom)};
          rect.width=rect.right-x;rect.height=rect.bottom-y;
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
        if (!active) return;
        if(!valid(range)) { conceal();return; }
        const rects = rectsFor(range);
        if (!rects.length) { conceal(); return; }
        if(host.style.display!=='block') host.style.display='block';
        if(host.popover && !host.matches(':popover-open')) host.showPopover();
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
          const p = index ? end : start, clip=clipBounds(range);
          node.style.display=p.x>=clip.left && p.x<=clip.right && p.y>=clip.top && p.y+p.height<=clip.bottom ? 'block' : 'none';
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
      document.addEventListener('selectionchange',()=>{selectionChanges++;});
      addEventListener('scroll',schedule,{passive:true,capture:true});
      addEventListener('resize',schedule,{passive:true});
      visualViewport?.addEventListener('resize',schedule,{passive:true});
      visualViewport?.addEventListener('scroll',schedule,{passive:true});
      globalThis.__linkletFindHighlight = {
        matches(value) {
          if(document.contentType && !/html|xml/u.test(document.contentType)) return {supported:false};
          hits=collect(value);searchQuery=value;
          const index=preferred(hits);
          return {supported:true,count:hits.length,preferred:index<0 ? null : index};
        },
        prepare(preserve) { if(!preserve) hide();pending=true; },
        showMatch(index, accent, animate, reduceMotion) {
          const r=hits[index];if(!r) {conceal();return;}
          setup();query=searchQuery;color=accent;reduced=reduceMotion;range=r.cloneRange();remember(range,index);active=true;pending=false;
          const rect=range.getBoundingClientRect();
          if(rect.top<0 || rect.bottom>innerHeight || rect.left<0 || rect.right>innerWidth)
            parentElement(range.startContainer)?.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});
          draw(animate);
          if(!raf) raf=requestAnimationFrame(track);
          if(!observing) {
            observing=true;
            observer=new MutationObserver(()=>{dirty=true;});watch();
          }
        },
        appearance(accent, reduceMotion) { color=accent; reduced=reduceMotion; if(active) draw(false); },
        hide,
        diagnostics() {
          return {active,query,color,reduced,animated:lastAnimation,rects:range ? rectsFor(range) : [],
            start:previous?.start ?? null,end:previous?.end ?? null,display:host?.style.display ?? 'none',
            endTransform:endHandle?.style.transform ?? '',endTransition:endHandle?.style.transition ?? '',
            selected:String(getSelection()),rangeText:range?.toString() ?? '',selectionChanges,pointerEvents:host?.style.pointerEvents ?? '',ariaHidden:host?.getAttribute('aria-hidden') ?? ''};
        }
      };
      const announce = () => webkit.messageHandlers.linkletFindHighlight.postMessage({event:'ready',frame});
      addEventListener('pageshow',announce);
      addEventListener('pagehide',() => { hide(); webkit.messageHandlers.linkletFindHighlight.postMessage({event:'gone',frame}); });
      announce();
    })();
    """#
}
