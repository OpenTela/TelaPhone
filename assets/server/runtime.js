var conLogEl = document.getElementById("con-log");
var consoleBuffer = [];
var consoleMaxSize = 500;

function clog(msg, cls) {
  var time = new Date().toISOString();
  var type = cls === "ce" ? "error" : cls === "cw" ? "warn" : "info";
  consoleBuffer.push({time: time, type: type, msg: msg});
  if (consoleBuffer.length > consoleMaxSize) consoleBuffer.shift();
  var d = document.createElement("div");
  if (cls) d.className = cls;
  d.textContent = msg;
  conLogEl.appendChild(d);
  conLogEl.scrollTop = 999999;
  if (cls === "ce" || cls === "cw") {
    try {
      fetch("/console", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({msg: msg, type: type})
      }).catch(function() {});
    } catch(e) {}
  }
  if (cls === "ce" && window.FlutterError) {
    window.FlutterError.postMessage(msg);
  }
}

window.getConsole = function(since) {
  if (!since) return consoleBuffer.slice();
  return consoleBuffer.filter(function(e) { return e.time > since; });
};
window.clearConsole = function() { consoleBuffer = []; conLogEl.innerHTML = ""; };

window.onerror = function(msg, src, line, col, err) {
  clog("[error]" + (line ? " (line " + line + ")" : "") + " " + msg, "ce");
  return true;
};
window.addEventListener("unhandledrejection", function(e) {
  clog("[promise] " + String(e.reason), "ce");
});

function getConText() {
  var text = "";
  var lines = conLogEl.querySelectorAll("div");
  for (var i = 0; i < lines.length; i++) text += lines[i].textContent + "\n";
  return text;
}
document.getElementById("copy-btn").addEventListener("click", function(e) {
  e.preventDefault();
  navigator.clipboard.writeText(getConText()).then(function() {
    document.getElementById("copy-btn").textContent = "OK!";
    setTimeout(function() { document.getElementById("copy-btn").textContent = "Copy"; }, 1200);
  });
});
document.getElementById("clear-btn").addEventListener("click", function(e) {
  e.preventDefault(); conLogEl.innerHTML = "";
});

// ======================== GLOBALS ========================
var appState = {};
var stateTypes = {};
var bindings = {};
var pages = {};
var widgets = {};
var groupDefaults = {}, groupPages = {}, groupOrient = {}, pageToGroup = {};
var currentPage = null, activeTimers = [], luaEngine = null, luaReady = false;

// ======================== STATE (typed) ========================
function coerceState(key, value) {
  var type = stateTypes[key] || "string";
  switch (type) {
    case "int":
      var n = parseInt(value, 10);
      return isNaN(n) ? 0 : n;
    case "float":
      var f = parseFloat(value);
      return isNaN(f) ? 0.0 : f;
    case "bool":
      if (typeof value === "boolean") return value;
      if (typeof value === "number") return value !== 0;
      return value === "true" || value === "1";
    default:
      return String(value ?? "");
  }
}

function getState(key) {
  var val = appState["_" + key];
  if (val === undefined) {
    var type = stateTypes[key] || "string";
    if (type === "int" || type === "float") return 0;
    if (type === "bool") return false;
    return "";
  }
  return val;
}

function getStateStr(key) {
  var val = appState["_" + key];
  if (val === undefined) return "";
  if (typeof val === "boolean") return val ? "true" : "false";
  return String(val);
}

function setState(key, value) {
  var typed = coerceState(key, value);
  var old = appState["_" + key];
  if (old === typed) return;
  appState["_" + key] = typed;
  var fns = bindings[key];
  if (fns) { for (var i = 0; i < fns.length; i++) fns[i](); }
}

function sub(key, fn) {
  if (!bindings[key]) bindings[key] = [];
  bindings[key].push(fn);
}
function extractVars(t) {
  var v = [], r = /\{(\w+)\}/g, m;
  while ((m = r.exec(t)) !== null) v.push(m[1]);
  return v;
}
function resolve(t) {
  return t.replace(/\{(\w+)\}/g, function(_, k) { return getStateStr(k); });
}

// ======================== UTILS ========================
function normUnit(v) {
  if (!v) return "";
  if (v.indexOf("%") >= 0) return v;
  if (/^\d+$/.test(v)) return v + "px";
  return v;
}
function normColor(v) {
  if (!v) return v;
  if (v.charAt(0) === "#") return v;
  var n = parseInt(v);
  if (!isNaN(n) && String(n) === v.trim()) return "#" + n.toString(16).padStart(6, "0");
  return v;
}

// ======================== LUA ========================
function callLua(fn) {
  if (!luaReady || !luaEngine) { clog("[no-lua] " + fn + "()", "cw"); return; }
  try {
    var f = luaEngine.global.get(fn);
    if (typeof f === "function") f();
    else clog("[lua] " + fn + " is not a function", "cw");
  } catch(err) { clog("[lua-err] " + fn + ": " + err.message, "ce"); }
}

function luaPreprocess(src) {
  var lines = src.split("\n"), names = [];
  var pat = /^(\s*)local\s+function\s+(\w+)\s*\(/;
  for (var i = 0; i < lines.length; i++) { var m = pat.exec(lines[i]); if (m) names.push(m[2]); }
  if (names.length === 0) return src;
  var out = "local " + names.join(", ") + "\n";
  for (var i = 0; i < lines.length; i++) {
    var m = pat.exec(lines[i]);
    if (m) out += m[1] + m[2] + " = function(" + lines[i].substring(m[0].length) + "\n";
    else out += lines[i] + "\n";
  }
  return out;
}

async function setupLua(app) {
  if (!luaReady || !luaEngine) return;
  var G = luaEngine.global;
  G.set("__fc_get_state", function(key) { return getState(key); });
  G.set("__fc_set_state", function(key, val) { setState(key, val); });
  await luaEngine.doString(
    "state = setmetatable({}, {" +
    "  __index = function(t, k) return __fc_get_state(k) end," +
    "  __newindex = function(t, k, v) __fc_set_state(k, v) end" +
    "})"
  );
  G.set("navigate", function(page) { navigateTo(page); });
  G.set("focus", function(id) {
    var w = widgets[id];
    if (w && w.tagName === "INPUT") { w.focus(); return true; }
    return false;
  });
  function cssVal(v) { var s = String(v); if (/^-?\d+(\.\d+)?$/.test(s)) return s + "px"; return s; }
  G.set("setAttr", function(id, attr, val) {
    var w = widgets[id]; if (!w) return;
    if (attr === "bgcolor") w.style.background = normColor(val);
    else if (attr === "color") w.style.color = normColor(val);
    else if (attr === "text") w.textContent = val;
    else if (attr === "visible") w.classList.toggle("fc-hidden", val !== "true" && val !== "1");
    else if (attr === "x") w.style.left = cssVal(val);
    else if (attr === "y") w.style.top = cssVal(val);
    else if (attr === "w") w.style.width = cssVal(val);
    else if (attr === "h") w.style.height = cssVal(val);
    else if (attr === "font") w.style.fontSize = cssVal(val);
    else if (attr === "radius") w.style.borderRadius = cssVal(val);
    else if (attr === "opacity") w.style.opacity = val;
    else if (attr === "z-index") w.style.zIndex = val;
  });
  G.set("getAttr", function(id, attr) {
    var w = widgets[id]; if (!w) return "";
    if (attr === "bgcolor") return w.style.background || w.style.backgroundColor || "";
    if (attr === "color") return w.style.color || "";
    if (attr === "text") return w.textContent || "";
    if (attr === "visible") return w.classList.contains("fc-hidden") ? "false" : "true";
    if (attr === "x") return w.style.left || "";
    if (attr === "y") return w.style.top || "";
    if (attr === "w") return w.style.width || "";
    if (attr === "h") return w.style.height || "";
    if (attr === "font") return w.style.fontSize || "";
    if (attr === "radius") return w.style.borderRadius || "";
    if (attr === "opacity") return w.style.opacity || "";
    if (attr === "z-index") return w.style.zIndex || "";
    return "";
  });
  G.set("print", function() {
    var parts = [];
    for (var i = 0; i < arguments.length; i++) parts.push(String(arguments[i]));
    clog("[lua] " + parts.join("\t"));
  });
  G.set("exit", function() { clog("[lua] exit()", "ci"); });
  await luaEngine.doString("app = { launch = function(name) print('[app.launch] ' .. tostring(name)) end }");
  G.set("setTimeout", function(ms, callback) {
    setTimeout(function() { if (typeof callback === "function") callback(); }, ms || 0);
  });
  await luaEngine.doString("net = { connected = function() return true end }");

  // canvas
  await luaEngine.doString([
    "canvas = {}",
    "canvas.clear = function(id, c) __fc_canvas('clear', id, c) end",
    "canvas.rect = function(id, x, y, w, h, c) __fc_canvas('rect', id, x, y, w, h, c) end",
    "canvas.pixel = function(id, x, y, c) __fc_canvas('pixel', id, x, y, 0, 0, c) end",
    "canvas.line = function(id, x1, y1, x2, y2, c) __fc_canvas('line', id, x1, y1, x2, y2, c) end",
    "canvas.circle = function(id, cx, cy, r, c) __fc_canvas('circle', id, cx, cy, r, 0, c) end",
    "canvas.refresh = function(id) end",
  ].join("\n"));
  G.set("__fc_canvas", function(op, id, a, b, c, d, e) {
    var w = widgets[id]; if (!w || w.tagName !== "CANVAS") return;
    var ctx = w.getContext("2d");
    if (op === "clear") { ctx.fillStyle = normColor(a) || "#000"; ctx.fillRect(0, 0, w.width, w.height); }
    else if (op === "rect") { ctx.fillStyle = normColor(e); ctx.fillRect(a, b, c, d); }
    else if (op === "pixel") { ctx.fillStyle = normColor(e); ctx.fillRect(a, b, 1, 1); }
    else if (op === "line") { ctx.strokeStyle = normColor(e); ctx.beginPath(); ctx.moveTo(a, b); ctx.lineTo(c, d); ctx.stroke(); }
    else if (op === "circle") { ctx.fillStyle = normColor(d || e); ctx.beginPath(); ctx.arc(a, b, c, 0, Math.PI*2); ctx.fill(); }
  });

  // os.time / os.date
  G.set("__js_time", function(y, m, d, h, min, s) {
    if (y === undefined) return Math.floor(Date.now() / 1000);
    var day = (d !== undefined && d !== null) ? d : 1;
    var date = new Date(y, (m || 1) - 1, day, h || 0, min || 0, s || 0);
    return Math.floor(date.getTime() / 1000);
  });
  G.set("__js_date", function(fmt, ts) {
    var d = ts ? new Date(ts * 1000) : new Date();
    if (fmt === "*t") {
      return {
        year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate(),
        hour: d.getHours(), min: d.getMinutes(), sec: d.getSeconds(),
        wday: d.getDay() + 1,
        yday: Math.floor((d - new Date(d.getFullYear(), 0, 0)) / 86400000)
      };
    }
    var pad = function(n) { return n < 10 ? "0" + n : "" + n; };
    return (fmt || "%c").replace("%%", "\0")
      .replace("%Y", d.getFullYear()).replace("%m", pad(d.getMonth() + 1))
      .replace("%d", pad(d.getDate())).replace("%H", pad(d.getHours()))
      .replace("%M", pad(d.getMinutes())).replace("%S", pad(d.getSeconds()))
      .replace("%c", d.toLocaleString()).replace("\0", "%");
  });
  await luaEngine.doString(
    "os.time = function(t)\n" +
    "  if t == nil then return __js_time()\n" +
    "  else return __js_time(t.year, t.month, t.day, t.hour, t.min, t.sec) end\n" +
    "end\n" +
    "os.date = function(fmt, ts)\n" +
    "  if fmt == '*t' then return __js_date('*t', ts)\n" +
    "  else return __js_date(fmt or '%c', ts) end\n" +
    "end"
  );

  // json
  G.set("__fc_json_parse", function(s) { try { return JSON.parse(s); } catch(e) { return null; } });
  G.set("__fc_json_stringify", function(t) { try { return JSON.stringify(t); } catch(e) { return "{}"; } });
  await luaEngine.doString(
    "json = {}\njson.parse = function(s) return __fc_json_parse(s) end\n" +
    "json.decode = json.parse\njson.stringify = function(t) return __fc_json_stringify(t) end\njson.encode = json.stringify"
  );

  // fetch
  G.set("__js_fetch", function(url, method, body, format, fields, callback) {
    var opts = { method: method || "GET" };
    if (body) { opts.body = body; opts.headers = { "Content-Type": "application/json" }; }
    window.fetch(url, opts).then(function(resp) {
      var status = resp.status, ok = status >= 200 && status < 300;
      return resp.text().then(function(text) {
        var result = { status: status, ok: ok, body: text };
        if (format === "json" && text) {
          try {
            var json = JSON.parse(text);
            if (fields && fields.length > 0) {
              var filtered = {};
              for (var i = 0; i < fields.length; i++) { var f = fields[i]; if (json[f] !== undefined) filtered[f] = json[f]; }
              result.body = filtered;
            } else { result.body = json; }
          } catch(e) { result.body = text; }
        }
        return result;
      });
    }).then(function(result) {
      if (typeof callback === "function") callback(result);
    }).catch(function(err) {
      if (typeof callback === "function") callback({ status: 0, ok: false, error: err.message, body: "" });
    });
  });
  await luaEngine.doString(
    "function fetch(opts, callback)\n" +
    "  local url = opts.url or ''\n  local method = opts.method or 'GET'\n" +
    "  local body = opts.body\n  local format = opts.format\n  local fields = opts.fields or {}\n" +
    "  __js_fetch(url, method, body, format, fields, callback)\nend"
  );

  var se = app.querySelector("script");
  if (se && se.textContent && se.textContent !== "X") {
    try { await luaEngine.doString(luaPreprocess(se.textContent)); clog("Script OK", "ci"); }
    catch(err) { clog("[lua-err] " + err.message, "ce"); }
  }
}

// ======================== XML PARSER ========================
var SCRIPT_OPEN = "<" + "script";
var SCRIPT_CLOSE = "</" + "script>";
function parseXML(src) {
  var luaCode = "";
  var i1 = src.indexOf(SCRIPT_OPEN);
  if (i1 >= 0) {
    var i2 = src.indexOf(SCRIPT_CLOSE, i1);
    if (i2 > i1) { var tagEnd = src.indexOf(">", i1); luaCode = src.substring(tagEnd + 1, i2); src = src.substring(0, tagEnd + 1) + "X" + src.substring(i2); }
  }
  var selfClose = ["bluetooth","timer","string","int","bool","float","image","slider","switch","input"];
  var scRe = new RegExp("<(" + selfClose.join("|") + ")\\b([^>]*?)\\/?\\s*>", "g");
  src = src.replace(scRe, function(m, t, a) { if (m.charAt(m.length - 2) === "/") return m; return "<" + t + a + "/>"; });
  var doc = new DOMParser().parseFromString(src, "text/xml");
  var err = doc.querySelector("parsererror");
  if (err) { clog("[xml-err] " + err.textContent.substring(0, 200), "ce"); throw new Error("XML parse error"); }
  var se = doc.querySelector("script");
  if (se) se.textContent = luaCode;
  return doc.documentElement;
}

// ======================== CSS ENGINE ========================
var cssRules = [];
function parseAppCSS(app) {
  cssRules = [];
  var styleEl = app.querySelector("style");
  if (!styleEl) return;
  var raw = (styleEl.textContent || "").replace(/\/\*[\s\S]*?\*\//g, "");
  var re = /([^{}]+)\{([^{}]+)\}/g, m;
  while ((m = re.exec(raw)) !== null) {
    var propsStr = m[2].trim(), props = {};
    propsStr.split(";").forEach(function(p) {
      var c = p.indexOf(":"); if (c < 0) return;
      var k = p.substring(0, c).trim().toLowerCase(), v = p.substring(c+1).trim();
      if (k && v) props[k] = v;
    });
    m[1].trim().split(",").forEach(function(sel) {
      sel = sel.trim(); if (!sel) return;
      var tagName = null, classes = [], dotParts = sel.split(".");
      if (dotParts[0]) tagName = dotParts[0].toLowerCase();
      for (var i = 1; i < dotParts.length; i++) if (dotParts[i]) classes.push(dotParts[i]);
      cssRules.push({ tag: tagName, classes: classes, props: props, sp: (tagName?1:0) + classes.length*10 });
    });
  }
  cssRules.sort(function(a, b) { return a.sp - b.sp; });
}
function matchCSS(tagName, classList) {
  var result = {}; tagName = tagName.toLowerCase();
  for (var i = 0; i < cssRules.length; i++) {
    var r = cssRules[i];
    if (r.tag && r.tag !== tagName) continue;
    var ok = true;
    for (var j = 0; j < r.classes.length; j++) if (classList.indexOf(r.classes[j]) < 0) { ok = false; break; }
    if (!ok) continue;
    for (var k in r.props) result[k] = r.props[k];
  }
  return result;
}
function applyCSSProps(el, props) {
  if (!el._cssP) el._cssP = {};
  for (var key in props) {
    var v = props[key];
    switch (key) {
      case "background": case "bgcolor": case "background-color": el.style.background = normColor(v); el._cssP.background = 1; break;
      case "color": el.style.color = normColor(v); el._cssP.color = 1; break;
      case "font-size": case "font": el.style.fontSize = /^\d+$/.test(v)?v+"px":v; el._cssP.fontSize = 1; break;
      case "border-radius": case "radius": el.style.borderRadius = /^\d+$/.test(v)?v+"px":v; el._cssP.borderRadius = 1; break;
      case "width": el.style.width = normUnit(v); el._cssP.width = 1; break;
      case "height": el.style.height = normUnit(v); el._cssP.height = 1; break;
      case "padding-left": el.style.paddingLeft = /^\d+$/.test(v)?v+"px":v; el._cssP.paddingLeft = 1; break;
      case "padding-right": el.style.paddingRight = /^\d+$/.test(v)?v+"px":v; el._cssP.paddingRight = 1; break;
      case "padding-top": el.style.paddingTop = /^\d+$/.test(v)?v+"px":v; el._cssP.paddingTop = 1; break;
      case "padding-bottom": el.style.paddingBottom = /^\d+$/.test(v)?v+"px":v; el._cssP.paddingBottom = 1; break;
      case "padding": el.style.padding = /^\d+$/.test(v)?v+"px":v; el._cssP.padding = 1; break;
      case "opacity": el.style.opacity = v; el._cssP.opacity = 1; break;
      case "text-align": el.style.textAlign = v; el._cssP.textAlign = 1; break;
    }
  }
}
function getClassList(xml) {
  var c = xml.getAttribute("class") || "";
  if (c.indexOf("{") >= 0) c = resolve(c);
  return c ? c.split(/\s+/).filter(function(s){return s;}) : [];
}
function applyDynamicClass(el, xml, tagName) {
  var c = xml.getAttribute("class") || "", vars = extractVars(c);
  if (!vars.length) return;
  var fn = function() {
    var cls = resolve(c).split(/\s+/).filter(function(s){return s;});
    if (el._cssP) { for (var p in el._cssP) el.style[p] = ""; el._cssP = {}; }
    applyCSSProps(el, matchCSS(tagName, cls));
  };
  for (var i = 0; i < vars.length; i++) sub(vars[i], fn);
  fn();
}

// ======================== VALIDATION ========================
window.validateCode = function(xmlStr) {
  var errors = [], warnings = [], app;
  try { app = parseXML(xmlStr); }
  catch(e) { errors.push({code:"XML_PARSE",msg:"XML: "+e.message}); return {valid:false,errors:errors,warnings:warnings}; }
  if (app.tagName.toLowerCase() !== "app") errors.push({code:"NO_APP",msg:"Root must be <app>"});
  var stateVars = {}, stateEl = app.querySelector("state");
  if (stateEl) for (var i = 0; i < stateEl.children.length; i++) { var n = stateEl.children[i].getAttribute("name"); if (n) stateVars[n] = true; }
  var pageIds = {}, allP = app.querySelectorAll("page");
  for (var i = 0; i < allP.length; i++) { var p = allP[i].getAttribute("id"); if (p) pageIds[p] = true; }
  var usedB = {}, usedH = {}, allE = app.querySelectorAll("*");
  for (var i = 0; i < allE.length; i++) {
    var el = allE[i], bind = el.getAttribute("bind");
    if (bind) usedB[bind] = true;
    for (var j = 0; j < el.attributes.length; j++) {
      var ms = el.attributes[j].value.match(/\{([^}]+)\}/g);
      if (ms) ms.forEach(function(m){usedB[m.slice(1,-1)]=true;});
    }
    ["onclick","onchange","onenter","onblur","onhold","call"].forEach(function(a){ var f = el.getAttribute(a); if(f) usedH[f]=true; });
  }
  for (var v in usedB) if (!stateVars[v]) warnings.push({code:"UNBOUND",msg:"{"+v+"} not in <state>"});
  var allButtons = app.querySelectorAll("button");
  for (var i = 0; i < allButtons.length; i++) {
    var btn = allButtons[i], nested = btn.querySelectorAll("label");
    if (nested.length > 1) {
      var btnId = btn.getAttribute("id") || btn.getAttribute("onclick") || ("button #"+(i+1));
      warnings.push({code:"MULTI_LABEL", msg:"<button "+btnId+"> has "+nested.length+" nested <label>"});
    }
  }
  var se = app.querySelector("script"), lc = se ? se.textContent : "", lf = {};
  var m2, re2 = /function\s+([a-zA-Z_]\w*)\s*\(/g;
  while ((m2 = re2.exec(lc)) !== null) lf[m2[1]] = true;
  for (var fn in usedH) if (!lf[fn]) errors.push({code:"MISSING_FUNC",msg:fn+" not found"});
  var emojiRegex = /[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{FE00}-\u{FE0F}]|[\u{1F000}-\u{1F02F}]|[\u{1F0A0}-\u{1F0FF}]|[\u25B6\u25C0\u23F8-\u23FA]/gu;
  var emojiMatches = xmlStr.match(emojiRegex);
  if (emojiMatches) {
    var unique = Array.from(new Set(emojiMatches));
    errors.push({code:"EMOJI", msg:"Unicode emoji unsupported: " + unique.slice(0,5).join(" ")});
  }
  return {valid:!errors.length, errors:errors, warnings:warnings,
    stats:{pages:Object.keys(pageIds).length, stateVars:Object.keys(stateVars).length, functions:Object.keys(lf).length}};
};

// ======================== BUILD APP ========================
async function buildApp(xmlStr) {
  appState = {}; stateTypes = {}; bindings = {}; pages = {}; widgets = {};
  groupDefaults = {}; groupPages = {}; groupOrient = {}; pageToGroup = {};
  currentPage = null;
  activeTimers.forEach(function(t){clearInterval(t);}); activeTimers = [];
  window._appOnclicks = [];
  var screen = document.getElementById("screen");
  document.getElementById("load-screen").style.display = "none";
  var old = screen.querySelectorAll(".fc-page,.fc-dots");
  for (var i = 0; i < old.length; i++) old[i].remove();
  clog("Parsing...", "ci");
  var app = parseXML(xmlStr);
  parseAppCSS(app);
  var emojiRegex = /[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{FE00}-\u{FE0F}]|[\u{1F000}-\u{1F02F}]|[\u{1F0A0}-\u{1F0FF}]|[\u25B6\u25C0\u23F8-\u23FA]/gu;
  var emojiMatches = xmlStr.match(emojiRegex);
  if (emojiMatches) {
    var unique = Array.from(new Set(emojiMatches));
    clog("[error] Unicode emoji unsupported: " + unique.slice(0,5).join(" "), "ce");
  }
  var stateEl = app.querySelector("state");
  if (stateEl) {
    var ch = stateEl.children;
    for (var i = 0; i < ch.length; i++) {
      var name = ch[i].getAttribute("name"), def = ch[i].getAttribute("default") || "";
      stateTypes[name] = ch[i].tagName.toLowerCase();
      appState["_" + name] = coerceState(name, def);
    }
    clog("State: " + ch.length + " vars", "ci");
  }
  var uiEl = app.querySelector("ui");
  var defaultPage = uiEl ? (uiEl.getAttribute("default") || "").replace(/^\//, "") : "";
  function processContainer(container) {
    var ch = container.children;
    for (var i = 0; i < ch.length; i++) {
      var tag = ch[i].tagName.toLowerCase();
      if (tag === "page") {
        var pid = ch[i].getAttribute("id");
        var div = document.createElement("div"); div.className = "fc-page"; div.id = "page-" + pid;
        div.style.background = normColor(ch[i].getAttribute("bgcolor")) || "#000";
        screen.appendChild(div); pages[pid] = div;
        buildWidgets(ch[i], div); clog("Page: " + pid, "ci");
      } else if (tag === "group") {
        var gid = ch[i].getAttribute("id");
        var orient = ch[i].getAttribute("orientation") || "horizontal";
        if (orient === "horizontal" || orient === "h") orient = "h"; else orient = "v";
        if (gid) { groupDefaults[gid] = ch[i].getAttribute("default") || null; groupPages[gid] = []; groupOrient[gid] = orient; }
        var gch = ch[i].children;
        for (var j = 0; j < gch.length; j++) {
          if (gch[j].tagName.toLowerCase() === "page") {
            var gpid = gch[j].getAttribute("id");
            if (gid) { groupPages[gid].push(gpid); pageToGroup[gpid] = gid; }
          }
        }
        processContainer(ch[i]);
        if (gid && !groupDefaults[gid] && groupPages[gid].length) groupDefaults[gid] = groupPages[gid][0];
        var indicator = ch[i].getAttribute("indicator") || "scrollbar";
        if (indicator === "dots" && gid && groupPages[gid].length > 1) {
          var dd = document.createElement("div"); dd.className = "fc-dots"; dd.id = "dots-" + gid;
          dd.style.cssText = "position:absolute;bottom:4px;left:0;right:0;display:flex;justify-content:center;gap:6px;z-index:10;pointer-events:none;";
          for (var j = 0; j < groupPages[gid].length; j++) {
            var dot = document.createElement("div");
            dot.style.cssText = "width:8px;height:8px;border-radius:50%;background:#555;transition:background 0.2s;";
            dot.dataset.page = groupPages[gid][j]; dd.appendChild(dot);
          }
          screen.appendChild(dd);
        }
      }
    }
  }
  if (uiEl) processContainer(uiEl);
  setupGroupSwipe(screen);
  var startPage = defaultPage || Object.keys(pages)[0] || "";
  clog("Start: " + startPage, "ci");
  if (startPage) navigateTo(startPage);
  if (luaReady) {
    if (luaEngine) try { luaEngine.global.close(); } catch(e) {}
    luaEngine = await new wasmoon.LuaFactory().createEngine();
    await setupLua(app);
  }
  var timerEls = app.querySelectorAll("timer");
  for (var i = 0; i < timerEls.length; i++) {
    var iv = parseInt(timerEls[i].getAttribute("interval")) || 1000;
    var fn = timerEls[i].getAttribute("call") || "";
    if (fn) (function(f, t) { activeTimers.push(setInterval(function(){callLua(f);}, t)); })(fn, iv);
  }
  clog("Done!", "ci");
}

// ======================== GROUP SWIPE ========================
function setupGroupSwipe(screen) {
  var sx = 0, sy = 0, active = false;
  function handleSwipe(dx, dy) {
    if (!currentPage) return;
    var gid = pageToGroup[currentPage]; if (!gid) return;
    var plist = groupPages[gid], orient = groupOrient[gid], idx = plist.indexOf(currentPage);
    if (idx < 0) return; var T = 50;
    if (orient === "h") {
      if (Math.abs(dx) < T || Math.abs(dy) > Math.abs(dx)) return;
      if (dx < 0 && idx < plist.length-1) navigateTo(plist[idx+1]);
      else if (dx > 0 && idx > 0) navigateTo(plist[idx-1]);
    } else {
      if (Math.abs(dy) < T || Math.abs(dx) > Math.abs(dy)) return;
      if (dy < 0 && idx < plist.length-1) navigateTo(plist[idx+1]);
      else if (dy > 0 && idx > 0) navigateTo(plist[idx-1]);
    }
  }
  screen.addEventListener("touchstart", function(e) { if (e.touches.length===1) { sx=e.touches[0].clientX; sy=e.touches[0].clientY; active=true; } }, {passive:true});
  screen.addEventListener("touchend", function(e) { if (!active) return; active=false; handleSwipe(e.changedTouches[0].clientX-sx, e.changedTouches[0].clientY-sy); }, {passive:true});
  screen.addEventListener("mousedown", function(e) { sx=e.clientX; sy=e.clientY; active=true; });
  screen.addEventListener("mouseup", function(e) { if (!active) return; active=false; handleSwipe(e.clientX-sx, e.clientY-sy); });
}

// ======================== WIDGETS ========================
function buildWidgets(pageXml, pageDom) {
  var ch = pageXml.children;
  for (var i = 0; i < ch.length; i++) {
    var t = ch[i].tagName.toLowerCase();
    if (t==="label") buildLabel(ch[i], pageDom);
    else if (t==="button") buildButton(ch[i], pageDom);
    else if (t==="input") buildInput(ch[i], pageDom);
    else if (t==="slider") buildSlider(ch[i], pageDom);
    else if (t==="switch") buildSwitch(ch[i], pageDom);
    else if (t==="image") buildImage(ch[i], pageDom);
    else if (t==="canvas") buildCanvas(ch[i], pageDom);
  }
}

// ======================== GEOMETRY ========================
function applyGeometry(el, xml) {
  var x = xml.getAttribute("x"), y = xml.getAttribute("y");
  var w = xml.getAttribute("w"), h = xml.getAttribute("h");
  if (x) el.style.left = normUnit(x);
  if (y) el.style.top = normUnit(y);
  if (w) el.style.width = normUnit(w);
  if (h) el.style.height = normUnit(h);
  var r = xml.getAttribute("radius");
  if (r !== null && r !== undefined) el.style.borderRadius = /^\d+$/.test(r) ? r+"px" : r;
  var z = xml.getAttribute("z") || xml.getAttribute("zindex") || xml.getAttribute("z-index");
  if (z) el.style.zIndex = z;
  var al = xml.getAttribute("align"), va = xml.getAttribute("valign");
  if (al) {
    var p = al.split(/\s+/);
    if (!x) {
      if (p[0]==="center") { el.style.left="50%"; el.style.transform="translateX(-50%)"; }
      else if (p[0]==="right") el.style.right="0";
      else if (p[0]==="left") el.style.left="0";
    }
    if (p[1] && !y) {
      if (p[1]==="center") { el.style.top="50%"; el.style.transform=(el.style.transform||"")+" translateY(-50%)"; }
      else if (p[1]==="bottom") el.style.bottom="0";
      else if (p[1]==="top") el.style.top="0";
    }
  }
  if (va && !y) {
    if (va==="center") { el.style.top="50%"; el.style.transform=(el.style.transform||"")+" translateY(-50%)"; }
    else if (va==="bottom") el.style.bottom="0";
    else if (va==="top") el.style.top="0";
  }
}
function applyFont(el, xml) { var f = xml.getAttribute("font"); if (f) el.style.fontSize = f + "px"; }
function applyTextAlign(el, xml) {
  var ta = xml.getAttribute("text-align"), tva = xml.getAttribute("text-valign");
  if (ta) {
    var p = ta.split(/\s+/);
    if (p[0]==="center") el.style.justifyContent="center";
    else if (p[0]==="right") el.style.justifyContent="flex-end";
    else if (p[0]==="left") el.style.justifyContent="flex-start";
    if (p[1]==="center") el.style.alignItems="center";
    else if (p[1]==="bottom") el.style.alignItems="flex-end";
    else if (p[1]==="top") el.style.alignItems="flex-start";
  }
  if (tva) {
    if (tva==="center") el.style.alignItems="center";
    else if (tva==="bottom") el.style.alignItems="flex-end";
    else if (tva==="top") el.style.alignItems="flex-start";
  }
  var al = xml.getAttribute("align"), hasX = xml.getAttribute("x");
  if (al && hasX && !ta) {
    var p = al.split(/\s+/);
    if (p[0]==="right") el.style.justifyContent="flex-end";
    else if (p[0]==="center") el.style.justifyContent="center";
    else if (p[0]==="left") el.style.justifyContent="flex-start";
  }
}
function applyColor(el, xml, attr, prop) {
  var v = xml.getAttribute(attr); if (!v) return;
  if (v.charAt(0)==="{" && v.charAt(v.length-1)==="}") {
    var vn = v.substring(1, v.length-1);
    var fn = function() { var c = getStateStr(vn); if (c) el.style[prop] = normColor(c); };
    sub(vn, fn); fn();
  } else el.style[prop] = normColor(v);
}
function applyVisible(el, xml) {
  var v = xml.getAttribute("visible"); if (!v) return;
  if (v.charAt(0)==="{" && v.charAt(v.length-1)==="}") {
    var vn = v.substring(1, v.length-1);
    var fn = function() { var s = getStateStr(vn); el.classList.toggle("fc-hidden", s!=="true" && s!=="1"); };
    sub(vn, fn); fn();
  }
}
function applyText(el, xml) {
  var raw = xml.textContent.trim(); if (!raw || raw==="X") return;
  var vars = extractVars(raw), ovMode = xml.getAttribute("overflow");
  if (vars.length) {
    var fn = function() {
      var text = resolve(raw);
      if (ovMode==="scroll" && el._scrollInner) el._scrollInner.textContent = text+"   "+text;
      else el.textContent = text;
    };
    for (var i = 0; i < vars.length; i++) sub(vars[i], fn);
    fn();
  } else el.textContent = raw;
}
function applyOverflow(el, xml) {
  var ov = xml.getAttribute("overflow"); if (!ov) return;
  if (ov==="ellipsis") el.classList.add("fc-overflow-ellipsis");
  else if (ov==="clip") el.classList.add("fc-overflow-clip");
  else if (ov==="scroll") {
    el.classList.add("fc-overflow-scroll");
    var t = el.textContent||""; el.innerHTML = "";
    var inner = document.createElement("span"); inner.className="fc-scroll-inner";
    inner.textContent = t+"   "+t; el.appendChild(inner); el._scrollInner = inner;
  }
}
function buildLabel(xml, parent) {
  var el = document.createElement("div"); el.className = "fc-label";
  var id = xml.getAttribute("id"); if (id) widgets[id] = el;
  applyCSSProps(el, matchCSS("label", getClassList(xml)));
  applyGeometry(el,xml); applyFont(el,xml); applyTextAlign(el,xml);
  applyColor(el,xml,"color","color"); applyColor(el,xml,"bgcolor","background");
  applyVisible(el,xml); applyText(el,xml); applyOverflow(el,xml);
  applyDynamicClass(el,xml,"label"); parent.appendChild(el);
}
function buildButton(xml, parent) {
  var el = document.createElement("div"); el.className = "fc-button";
  var id = xml.getAttribute("id"); if (id) widgets[id] = el;
  el.style.background = "#333";
  applyCSSProps(el, matchCSS("button", getClassList(xml)));
  applyGeometry(el,xml); applyFont(el,xml); applyTextAlign(el,xml);
  applyColor(el,xml,"bgcolor","background"); applyColor(el,xml,"color","color");
  applyVisible(el,xml); applyText(el,xml);
  var iconSrc = xml.getAttribute("icon");
  if (iconSrc) {
    var sz = xml.getAttribute("iconsize") || "24";
    var img = document.createElement("img");
    img.src = iconSrc; img.style.width = sz+"px"; img.style.height = sz+"px"; img.style.objectFit = "contain";
    if (el.textContent) img.style.marginRight = "6px";
    el.insertBefore(img, el.firstChild);
  }
  var oc = xml.getAttribute("onclick"), hr = xml.getAttribute("href"), oh = xml.getAttribute("onhold");
  if (oc) { el.dataset.onclick = oc; if (!window._appOnclicks) window._appOnclicks = []; if (window._appOnclicks.indexOf(oc) === -1) window._appOnclicks.push(oc); }
  var holdFired = false, holdTimer = null;
  if (oh) {
    el.dataset.onhold = oh;
    el.addEventListener("pointerdown", function() { holdFired=false; holdTimer=setTimeout(function(){holdFired=true;callLua(oh);holdTimer=null;},500); });
    el.addEventListener("pointerup", function() { if(holdTimer){clearTimeout(holdTimer);holdTimer=null;} });
    el.addEventListener("pointerleave", function() { if(holdTimer){clearTimeout(holdTimer);holdTimer=null;} });
  }
  el.addEventListener("click", function() {
    if (holdFired) { holdFired=false; return; }
    if (hr) navigateTo(hr); else if (oc) callLua(oc);
  });
  applyDynamicClass(el,xml,"button"); parent.appendChild(el);
}
function buildInput(xml, parent) {
  var el = document.createElement("input"); el.className = "fc-input";
  el.type = xml.getAttribute("password")==="true" ? "password" : "text";
  var id = xml.getAttribute("id"); if (id) widgets[id] = el;
  applyCSSProps(el, matchCSS("input", getClassList(xml)));
  applyGeometry(el,xml); applyVisible(el,xml);
  applyColor(el,xml,"color","color"); applyColor(el,xml,"bgcolor","background");
  var ph = xml.getAttribute("placeholder"); if (ph) el.placeholder = ph;
  var bind = xml.getAttribute("bind");
  if (bind) {
    var fn = function() { if (document.activeElement!==el) el.value = getStateStr(bind); };
    sub(bind, fn); fn();
    el.addEventListener("input", function() { setState(bind, el.value); });
  }
  var onenter = xml.getAttribute("onenter");
  if (onenter) { el.dataset.onenter = onenter; el.addEventListener("keydown", function(e) { if (e.key==="Enter") { e.preventDefault(); el.blur(); callLua(onenter); } }); }
  var onblur = xml.getAttribute("onblur"), onchange = xml.getAttribute("onchange");
  if (onblur) el.dataset.onblur = onblur;
  el.addEventListener("blur", function() { if (onchange) callLua(onchange); if (onblur) callLua(onblur); });
  applyDynamicClass(el,xml,"input"); parent.appendChild(el);
}
function buildSlider(xml, parent) {
  var el = document.createElement("input"); el.className = "fc-slider"; el.type = "range";
  var id = xml.getAttribute("id"); if (id) widgets[id] = el;
  applyCSSProps(el, matchCSS("slider", getClassList(xml)));
  applyGeometry(el,xml); applyVisible(el,xml);
  el.min = xml.getAttribute("min")||"0"; el.max = xml.getAttribute("max")||"100";
  var bind = xml.getAttribute("bind");
  if (bind) {
    var fn = function() { el.value = getStateStr(bind)||"0"; }; sub(bind,fn); fn();
    el.addEventListener("input", function() { setState(bind, el.value); });
  }
  var onchange = xml.getAttribute("onchange");
  if (onchange) el.addEventListener("input", function() { callLua(onchange); });
  parent.appendChild(el);
}
function buildSwitch(xml, parent) {
  var el = document.createElement("button"); el.className = "fc-switch";
  var id = xml.getAttribute("id"); if (id) widgets[id] = el;
  applyCSSProps(el, matchCSS("switch", getClassList(xml)));
  applyGeometry(el,xml);
  if (!xml.getAttribute("w")) el.style.width = "50px";
  if (!xml.getAttribute("h")) el.style.height = "26px";
  var bind = xml.getAttribute("bind"), onchange = xml.getAttribute("onchange");
  function render() {
    var val = getState(bind);
    var on = (val === true) || (val === "true") || (val === "1");
    el.style.background = on?"#4caf50":"#555"; el.style.borderRadius = "13px";
    el.innerHTML = '<div style="width:22px;height:22px;background:#fff;border-radius:50%;position:absolute;top:2px;left:'+(on?"26px":"2px")+';transition:left 0.15s"></div>';
  }
  if (bind) {
    sub(bind, render); render();
    el.addEventListener("click", function() {
      var val = getState(bind);
      var isOn = (val === true) || (val === "true") || (val === "1");
      setState(bind, isOn ? "false" : "true");
      if (onchange) callLua(onchange);
    });
  }
  applyVisible(el,xml); parent.appendChild(el);
}
function buildImage(xml, parent) {
  var el = document.createElement("img"); el.style.position = "absolute"; el.style.objectFit = "contain";
  var id = xml.getAttribute("id"); if (id) widgets[id] = el;
  applyCSSProps(el, matchCSS("image", getClassList(xml)));
  applyGeometry(el,xml); applyVisible(el,xml);
  var src = xml.getAttribute("src"); if (src) el.src = src;
  el.onerror = function() { el.style.display="none"; };
  parent.appendChild(el);
}
function buildCanvas(xml, parent) {
  var el = document.createElement("canvas"); el.style.position = "absolute";
  var id = xml.getAttribute("id"); if (id) widgets[id] = el;
  applyGeometry(el,xml); applyVisible(el,xml);
  var wA = xml.getAttribute("w"), hA = xml.getAttribute("h");
  el.width = (wA && wA.indexOf("%")>=0) ? Math.round(410*parseInt(wA)/100) : (parseInt(wA)||410);
  el.height = (hA && hA.indexOf("%")>=0) ? Math.round(502*parseInt(hA)/100) : (parseInt(hA)||502);
  parent.appendChild(el);
}

// ======================== NAVIGATION ========================
function showPage(id) {
  var c = id.replace(/^\//, "");
  Object.keys(pages).forEach(function(k){pages[k].classList.remove("active");});
  if (pages[c]) { pages[c].classList.add("active"); currentPage = c; }
  var allDots = document.querySelectorAll(".fc-dots");
  for (var i = 0; i < allDots.length; i++) allDots[i].style.display = "none";
  var gid = pageToGroup[c];
  if (gid) {
    var de = document.getElementById("dots-"+gid);
    if (de) { de.style.display = "flex"; var ds = de.children; for (var i=0;i<ds.length;i++) ds[i].style.background = ds[i].dataset.page===c?"#fff":"#555"; }
  }
}
function navigateTo(target) {
  var c = target.replace(/^\//, "");
  if (!pages[c] && groupDefaults[c]) c = groupDefaults[c];
  showPage(c);
}

// ======================== AUTO-TEST ========================
var autoTestErrors = [];
function runAutoTest() {
  if (!luaReady) return { success: false, error: "Lua not ready" };
  autoTestErrors = [];
  var handlers = new Map();
  var activePage = document.querySelector(".fc-page.active") || document.querySelector(".fc-page");
  var allW = activePage ? activePage.querySelectorAll("*") : document.querySelectorAll(".fc-button,.fc-label,.fc-input,.fc-switch,.fc-slider");
  allW.forEach(function(el) {
    ["onclick","onchange","onenter","onhold","onblur"].forEach(function(ev) {
      var fn = el.dataset[ev];
      if (fn && fn.trim()) {
        if (!handlers.has(fn)) handlers.set(fn, { types: [], elements: [] });
        handlers.get(fn).types.push(ev);
        handlers.get(fn).elements.push(el.id || el.className);
      }
    });
  });
  if (window._appOnclicks) window._appOnclicks.forEach(function(fn) {
    if (!handlers.has(fn)) handlers.set(fn, { types: ["onclick"], elements: ["registered"] });
  });
  var results = [], tested = 0;
  handlers.forEach(function(info, fn) {
    try {
      var f = luaEngine.global.get(fn);
      if (typeof f === "function") {
        if (info.types.includes("onclick") || info.types.includes("onenter") || info.types.includes("onhold")) f();
        results.push({ func: fn, status: "ok", types: info.types }); tested++;
      } else {
        var msg = "'" + fn + "' not found in Lua";
        results.push({ func: fn, status: "error", message: msg }); autoTestErrors.push(msg);
      }
    } catch(err) {
      var msg = fn + "(): " + err.message;
      results.push({ func: fn, status: "error", message: msg }); autoTestErrors.push(msg);
    }
  });
  return { success: autoTestErrors.length === 0, tested: tested, totalHandlers: handlers.size, errors: autoTestErrors, results: results };
}
window.runAutoTest = runAutoTest;
window.getAutoTestErrors = function() { return autoTestErrors; };

// ======================== LOAD ========================
document.getElementById("run-btn").addEventListener("click", function() {
  var src = document.getElementById("app-source").value.trim();
  if (src) buildApp(src).catch(function(e){clog("[err] "+e.message,"ce");});
});
var scr = document.getElementById("screen");
scr.addEventListener("dragover", function(e){e.preventDefault();});
scr.addEventListener("drop", function(e) {
  e.preventDefault(); var f = e.dataTransfer.files[0];
  if (f) { var r = new FileReader(); r.onload = function(ev){buildApp(ev.target.result).catch(function(err){clog("[err] "+err.message,"ce");});}; r.readAsText(f); }
});
window.loadApp = function(code) { return buildApp(code); };

// ======================== INIT ========================
clog("Loading Lua...", "ci");
var factory = new wasmoon.LuaFactory();
factory.createEngine().then(function(engine) {
  luaEngine = engine; luaReady = true;
  clog("Lua ready!", "ci");
  document.getElementById("lua-status").textContent = "Lua ready!";
  if (window.location.pathname === '/app') {
    var autoTest = new URLSearchParams(window.location.search).get("autotest") === "1";
    window.fetch('/app/code').then(function(res){if(res.ok)return res.text();return null;}).then(function(code) {
      if (code) {
        clog("Auto-loading app...","ci");
        buildApp(code).then(function() {
          if (autoTest) {
            clog("[autotest] Starting...", "ci");
            setTimeout(function() {
              var result = runAutoTest();
              if (result.success) clog("[autotest] PASS: " + result.tested + " functions tested", "ci");
              else { result.errors.forEach(function(e){clog("[autotest-error] "+e,"ce");}); clog("[autotest] FAIL: "+result.errors.length+" errors","ce"); }
              clog("[autotest-done] " + JSON.stringify(result), "ci");
            }, 500);
          }
        }).catch(function(e){clog("[auto-err] "+e.message,"ce");});
      } else clog("No app loaded.","cw");
    }).catch(function(){clog("No app loaded","cw");});
  }
}).catch(function(err) {
  clog("[wasm-err] "+err.message,"ce");
  document.getElementById("lua-status").textContent = "Lua failed: "+err.message;
});

window.addEventListener('message', function(e) {
  if (e.data && e.data.type==='run' && e.data.code) {
    function tryLoad() {
      if (typeof luaReady!=='undefined' && luaReady) buildApp(e.data.code).catch(function(err){clog("[ide-err] "+err.message,"ce");});
      else setTimeout(tryLoad, 100);
    }
    tryLoad();
  }
});
