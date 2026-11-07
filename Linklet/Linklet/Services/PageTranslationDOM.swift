import WebKit

/// Only text nodes cross the isolated bridge. Page scripts cannot call the native
/// translator, and neither cookies, form values nor translated text are persisted.
@MainActor
final class PageTranslationDOM: NSObject, WKScriptMessageHandler {
    static let shared = PageTranslationDOM()
    static let world = WKContentWorld.world(name: "Linklet.Translation")
    private let installed = NSHashTable<WKUserContentController>.weakObjects()
    private let owners = NSMapTable<WKWebView, PageTranslationController>.weakToWeakObjects()
    private var frames: [ObjectIdentifier: [String: WKFrameInfo]] = [:]

    struct Entry {
        let frame: String
        let node: Int
        let text: String
    }
    struct Snapshot {
        var entries: [Entry] = []
        var languageHint = ""
        var sample = ""
    }

    func install(in content: WKUserContentController) {
        guard !installed.contains(content) else { return }
        installed.add(content)
        content.add(self, contentWorld: Self.world, name: "linkletTranslation")
        content.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: false, in: Self.world))
    }
    func attach(_ view: WKWebView, owner: PageTranslationController) {
        install(in: view.configuration.userContentController)
        owners.setObject(owner, forKey: view)
        view.evaluateJavaScript(Self.script, in: nil, in: Self.world) { _ in }
    }
    func detach(_ view: WKWebView) {
        restore(view)
        owners.removeObject(forKey: view)
        frames.removeValue(forKey: ObjectIdentifier(view))
    }
    func restore(_ view: WKWebView) {
        for (id, frame) in frames[ObjectIdentifier(view)] ?? [:] {
            view.callAsyncJavaScript("if (globalThis.__linkletTranslation?.id === id) globalThis.__linkletTranslation.restore()",
                                     arguments: ["id": id], in: frame, in: Self.world) { _ in }
        }
    }
    func restoreAndWait(_ view: WKWebView) async {
        for (id, frame) in frames[ObjectIdentifier(view)] ?? [:] {
            _ = try? await view.callAsyncJavaScript("if (globalThis.__linkletTranslation?.id === id) globalThis.__linkletTranslation.restore()",
                                                   arguments: ["id": id], in: frame, contentWorld: Self.world)
        }
    }
    func watch(_ view: WKWebView) async {
        for (id, frame) in frames[ObjectIdentifier(view)] ?? [:] {
            _ = try? await view.callAsyncJavaScript("if (globalThis.__linkletTranslation?.id === id) globalThis.__linkletTranslation.watch()",
                                                   arguments: ["id": id], in: frame, contentWorld: Self.world)
        }
    }
    func snapshot(_ view: WKWebView, limit: Int = 60) async -> Snapshot {
        var result = Snapshot()
        let known = (frames[ObjectIdentifier(view)] ?? [:]).sorted { a, b in
            if a.value.isMainFrame != b.value.isMainFrame { return a.value.isMainFrame }
            return a.key < b.key
        }
        for (id, frame) in known {
            guard result.entries.count < limit else { break }
            guard let value = try? await view.callAsyncJavaScript(
                "return globalThis.__linkletTranslation?.id === id ? globalThis.__linkletTranslation.take(limit) : null",
                arguments: ["id": id, "limit": limit - result.entries.count], in: frame, contentWorld: Self.world),
                  let data = value as? [String: Any] else { continue }
            if frame.isMainFrame { result.languageHint = data["language"] as? String ?? "" }
            for row in data["entries"] as? [[String: Any]] ?? [] {
                guard let node = row["id"] as? Int, let text = row["text"] as? String else { continue }
                result.entries.append(Entry(frame: id, node: node, text: text))
                if result.sample.count < 4000 { result.sample += " " + String(text.prefix(4000 - result.sample.count)) }
            }
        }
        return result
    }
    func apply(_ entries: [Entry], translations: [String], in view: WKWebView) async -> Int {
        guard entries.count == translations.count else { return 0 }
        var grouped: [String: [[String: Any]]] = [:]
        for (entry, text) in zip(entries, translations) {
            grouped[entry.frame, default: []].append(["id": entry.node, "text": text, "original": entry.text])
        }
        var applied = 0
        for (id, values) in grouped {
            guard let frame = frames[ObjectIdentifier(view)]?[id] else { continue }
            let value = try? await view.callAsyncJavaScript(
                "return globalThis.__linkletTranslation?.id === id ? globalThis.__linkletTranslation.apply(values) : 0",
                arguments: ["id": id, "values": values], in: frame, contentWorld: Self.world)
            applied += value as? Int ?? 0
        }
        return applied
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = message.webView, let data = message.body as? [String: String], let id = data["id"] else { return }
        let key = ObjectIdentifier(view)
        if data["event"] == "gone" { frames[key]?.removeValue(forKey: id); return }
        if data["event"] == "ready" {
            if message.frameInfo.isMainFrame { frames[key] = frames[key]?.filter { !$0.value.isMainFrame } ?? [:] }
            frames[key, default: [:]][id] = message.frameInfo
        }
        if data["event"] == "changed" || data["event"] == "ready" { owners.object(forKey: view)?.pageChanged() }
    }

    static let script = #"""
    (() => {
      if (globalThis.__linkletTranslation) return;
      const id = globalThis.crypto?.randomUUID?.() || (Date.now().toString(36) + Math.random().toString(36).slice(2)), records = new Map(), byNode = new WeakMap(), directions = new Map(), roots = new Set();
      let serial = 0, active = false, timer;
      const send = event => { try { webkit.messageHandlers.linkletTranslation.postMessage({id,event}); } catch (_) {} };
      const excluded = 'script,style,noscript,template,pre,code,kbd,samp,textarea,input,select,option,svg,math,[contenteditable],[translate="no"],.notranslate,[hidden],[aria-hidden="true"]';
      const eligible = node => {
        const parent = node.parentElement || node.getRootNode().host;
        if (!parent || !node.data.trim() || !/\p{L}/u.test(node.data)) return false;
        for (let element = parent; element; element = element.getRootNode().host) {
          if (element.closest(excluded)) return false;
        }
        const style = getComputedStyle(parent);
        return style.display !== 'none' && style.visibility !== 'hidden' && style.visibility !== 'collapse' && parent.getClientRects().length > 0;
      };
      const observe = () => {
        observer.observe(document.documentElement, {subtree:true,childList:true,characterData:true});
        for (const root of roots) {
          if (root.host.isConnected) observer.observe(root, {subtree:true,childList:true,characterData:true});
          else roots.delete(root);
        }
      };
      const observer = new MutationObserver(() => {
        if (!active) return;
        clearTimeout(timer); timer = setTimeout(() => send('changed'), 400);
      });
      const restore = () => {
        active = false; clearTimeout(timer); observer.disconnect();
        for (const record of records.values()) {
          if (record.node.isConnected && record.translated !== undefined && record.node.data === record.translated) record.node.data = record.original;
          byNode.delete(record.node);
        }
        for (const [element, dir] of directions) {
          if (element.getAttribute('dir') === 'auto') { if (dir === null) element.removeAttribute('dir'); else element.setAttribute('dir', dir); }
        }
        records.clear(); directions.clear(); roots.clear();
      };
      globalThis.__linkletTranslation = {id, restore, watch() { active = true; observe(); },
        take(limit) {
          const entries = [], pending = [document.body || document.documentElement];
          for (let index = 0; index < pending.length && entries.length < limit; index++) {
            const walker = document.createTreeWalker(pending[index], NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
            let node;
            while ((node = walker.nextNode()) && entries.length < limit) {
              if (node.nodeType === Node.ELEMENT_NODE) {
                if (node.shadowRoot) { roots.add(node.shadowRoot); pending.push(node.shadowRoot); }
                continue;
              }
              if (!eligible(node)) continue;
              let record = byNode.get(node);
              if (record && !records.has(record.id)) record = undefined;
              if (record && (node.data === record.translated || (record.attempts >= 3 && node.data === record.original))) continue;
              if (!record) {
                if (records.size >= 20000) break;
                record = {id:++serial, node, original:node.data}; records.set(record.id,record); byNode.set(node,record);
              } else if (node.data !== record.original) { record.original = node.data; record.translated = undefined; record.attempts = 0; }
              entries.push({id:record.id,text:record.original});
            }
          }
          for (const [key, record] of records) if (!record.node.isConnected) records.delete(key);
          return {language:document.documentElement.lang || '', entries};
        },
        apply(values) {
          observer.disconnect(); let count = 0;
          for (const value of values) {
            const record = records.get(value.id);
            if (!record || !record.node.isConnected || record.original !== value.original || record.node.data !== record.original || !eligible(record.node)) continue;
            const before = record.original.match(/^\s*/u)[0], after = record.original.match(/\s*$/u)[0];
            record.attempts = (record.attempts || 0) + 1;
            record.translated = before + value.text.trim() + after; record.node.data = record.translated;
            const block = record.node.parentElement?.closest('p,h1,h2,h3,h4,h5,h6,li,td,th,blockquote');
            if (block) { if (!directions.has(block)) directions.set(block,block.getAttribute('dir')); block.setAttribute('dir','auto'); }
            count++;
          }
          active = true; observe(); return count;
        }
      };
      send('ready');
      addEventListener('pagehide', () => { restore(); send('gone'); });
      addEventListener('pageshow', event => { if (event.persisted) send('ready'); });
    })();
    """#
}
