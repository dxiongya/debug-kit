#!/usr/bin/osascript -l JavaScript
// mac-input.js — debug-kit BACKGROUND input backend for macOS.
//
// Delivers interaction to a target app WITHOUT moving the real system cursor and
// WITHOUT stealing focus, using two macOS-native mechanisms:
//
//   • CGEventPostToPid(pid, event)  — posts mouse / scroll / key events straight to
//     the target process. The visible cursor never moves. (click/drag/scroll/key)
//   • Accessibility (AX) actions    — AXPress a control, or set a field's value,
//     fully in the background. (press / settext / type)
//
// This is the "don't hijack my pointer, operate in the background" path. Pair it with
// mac-overlay (the virtual pointer) so a human can still watch what's happening.
//
// Usage:  osascript -l JavaScript mac-input.js <app> <cmd> <args...>
//   <app> click  <x> <y> [left|right] [clicks]
//   <app> drag   <fx> <fy> <tx> <ty>
//   <app> scroll <deltaY> [deltaX] [x] [y]
//   <app> key    <keyspec>                 e.g. return, tab, cmd+s, cmd+shift+p
//   <app> type   <text>                    sets the focused field's value (AX)
//   <app> press  <name|desc> <value>       AXPress element; prints "center=x,y"
//   <app> settext <name|desc> <value> <text>  set element value (AX); prints center
//   <app> axcenter <name|desc> <value>     resolve element center only; prints "x,y"
//
// On success the element commands print "center=<x>,<y>" (top-left coords) so the
// caller can place the virtual pointer; coordinate commands print "ok".
// Requires Accessibility permission for the host process.

ObjC.import('CoreGraphics');
ObjC.import('AppKit');

// ─── Virtual keycodes (US layout) ───
var KC = {
  return:36, enter:36, tab:48, escape:53, esc:53, space:49, backspace:51, delete:51,
  up:126, down:125, left:123, right:124, home:115, end:119, page_up:116, page_down:121,
  pageup:116, pagedown:121,
  a:0,b:11,c:8,d:2,e:14,f:3,g:5,h:4,i:34,j:38,k:40,l:37,m:46,n:45,o:31,p:35,q:12,r:15,
  s:1,t:17,u:32,v:9,w:13,x:7,y:16,z:6,
  "0":29,"1":18,"2":19,"3":20,"4":21,"5":22,"6":23,"7":24,"8":25,"9":26
};
// ASCII char -> {code, shift} for the best-effort character typing fallback.
var CHAR = (function(){
  var m = {};
  "abcdefghijklmnopqrstuvwxyz".split("").forEach(function(c){ m[c] = {code:KC[c], shift:false}; });
  "abcdefghijklmnopqrstuvwxyz".toUpperCase().split("").forEach(function(c){ m[c] = {code:KC[c.toLowerCase()], shift:true}; });
  "0123456789".split("").forEach(function(c){ m[c] = {code:KC[c], shift:false}; });
  m[" "] = {code:49, shift:false};
  var pairs = [["-",27,false],["_",27,true],["=",24,false],["+",24,true],["[",33,false],["{",33,true],
    ["]",30,false],["}",30,true],[";",41,false],[":",41,true],["'",39,false],['"',39,true],
    [",",43,false],["<",43,true],[".",47,false],[">",47,true],["/",44,false],["?",44,true],
    ["\\",42,false],["|",42,true],["`",50,false],["~",50,true],
    ["1",18,false],["!",18,true],["2",19,false],["@",19,true],["3",20,false],["#",20,true],
    ["4",21,false],["$",21,true],["5",23,false],["%",23,true],["6",22,false],["^",22,true],
    ["7",26,false],["&",26,true],["8",28,false],["*",28,true],["9",25,false],["(",25,true],
    ["0",29,false],[")",29,true]];
  pairs.forEach(function(p){ m[p[0]] = {code:p[1], shift:p[2]}; });
  return m;
})();

var FLAGS = {
  cmd: $.kCGEventFlagMaskCommand, command: $.kCGEventFlagMaskCommand,
  ctrl: $.kCGEventFlagMaskControl, control: $.kCGEventFlagMaskControl,
  alt: $.kCGEventFlagMaskAlternate, option: $.kCGEventFlagMaskAlternate,
  shift: $.kCGEventFlagMaskShift
};

function die(msg){ throw msg; }  // caught in run(); prints the message, no stack noise

function getProc(se, app){
  try { return se.processes.byName(app); } catch(e){ die("ERR: process not found: " + app); }
}
// Resolve pid via NSWorkspace (pure ObjC) — faster and far more reliable than the
// System Events JXA `unixId()` accessor, which can hang.
function getPid(app){
  var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
  for (var i = 0; i < apps.count; i++){
    var a = apps.objectAtIndex(i);
    if (ObjC.unwrap(a.localizedName) === app) return a.processIdentifier;
  }
  die("ERR: app not running: " + app);
}

// ─── CGEventPostToPid primitives ───
function postMouseClick(pid, x, y, right, clicks){
  var pt = $.CGPointMake(x, y);
  var btn = right ? $.kCGMouseButtonRight : $.kCGMouseButtonLeft;
  var down = right ? $.kCGEventRightMouseDown : $.kCGEventLeftMouseDown;
  var up   = right ? $.kCGEventRightMouseUp   : $.kCGEventLeftMouseUp;
  for (var i = 0; i < clicks; i++){
    var d = $.CGEventCreateMouseEvent($(), down, pt, btn); $.CGEventPostToPid(pid, d);
    var u = $.CGEventCreateMouseEvent($(), up, pt, btn);   $.CGEventPostToPid(pid, u);
    delay(0.04);
  }
}
function postDrag(pid, fx, fy, tx, ty){
  var down = $.CGEventCreateMouseEvent($(), $.kCGEventLeftMouseDown, $.CGPointMake(fx,fy), $.kCGMouseButtonLeft);
  $.CGEventPostToPid(pid, down);
  var steps = 20;
  for (var i = 1; i <= steps; i++){
    var t = i/steps;
    var p = $.CGPointMake(fx + (tx-fx)*t, fy + (ty-fy)*t);
    var m = $.CGEventCreateMouseEvent($(), $.kCGEventLeftMouseDragged, p, $.kCGMouseButtonLeft);
    $.CGEventPostToPid(pid, m);
    delay(0.012);
  }
  var up = $.CGEventCreateMouseEvent($(), $.kCGEventLeftMouseUp, $.CGPointMake(tx,ty), $.kCGMouseButtonLeft);
  $.CGEventPostToPid(pid, up);
}
function postScroll(pid, dy, dx){
  // line units; vertical is the common case (wheelCount 1).
  var ev;
  if (dx && dx !== 0){
    ev = $.CGEventCreateScrollWheelEvent($(), $.kCGScrollEventUnitLine, 2, dy, dx);
  } else {
    ev = $.CGEventCreateScrollWheelEvent($(), $.kCGScrollEventUnitLine, 1, dy);
  }
  $.CGEventPostToPid(pid, ev);
}
function postKeyCode(pid, code, flagMask){
  var d = $.CGEventCreateKeyboardEvent($(), code, true);
  if (flagMask) $.CGEventSetFlags(d, flagMask);
  $.CGEventPostToPid(pid, d);
  var u = $.CGEventCreateKeyboardEvent($(), code, false);
  if (flagMask) $.CGEventSetFlags(u, flagMask);
  $.CGEventPostToPid(pid, u);
  delay(0.02);
}
function postChars(pid, text){
  for (var i = 0; i < text.length; i++){
    var spec = CHAR[text[i]];
    if (!spec) continue; // skip chars we can't map (use AX `type` for full unicode)
    postKeyCode(pid, spec.code, spec.shift ? $.kCGEventFlagMaskShift : 0);
  }
}

// ─── Accessibility element search ───
function findEl(root, matchType, value, wantRoles){
  var found = null, visited = 0, MAX_NODES = 800;
  function walk(el, depth){
    if (found || depth > 8 || visited > MAX_NODES) return;
    visited++;
    try {
      var role = el.role();
      var ok = true;
      if (wantRoles && wantRoles.indexOf(role) < 0) ok = false;
      if (ok){
        // Match against name AND description (and title) — apps vary in which they expose.
        // An empty `value` matches the first element of wantRoles (used for "first text field").
        var hay = [];
        try { var n = el.name(); if (n) hay.push("" + n); } catch(e){}
        try { var d2 = el.description(); if (d2) hay.push("" + d2); } catch(e){}
        try { var ti = el.title(); if (ti) hay.push("" + ti); } catch(e){}
        try { var id = el.attributes.byName("AXIdentifier").value(); if (id) hay.push("" + id); } catch(e){}
        var joined = hay.join(" ");
        if (value === "" || joined.indexOf(value) >= 0){ found = el; return; }
      }
    } catch(e){}
    var ch; try { ch = el.uiElements(); } catch(e){ return; }
    for (var i = 0; i < ch.length; i++) walk(ch[i], depth+1);
  }
  var wins; try { wins = root.windows(); } catch(e){ wins = []; }
  for (var w = 0; w < wins.length && !found; w++) walk(wins[w], 0);
  return found;
}
function findElPred(root, pred){
  var found = null, visited = 0, MAX_NODES = 800;
  function walk(el, depth){
    if (found || depth > 8 || visited > MAX_NODES) return;
    visited++;
    try { if (pred(el)) { found = el; return; } } catch(e){}
    var ch; try { ch = el.uiElements(); } catch(e){ return; }
    for (var i = 0; i < ch.length; i++) walk(ch[i], depth+1);
  }
  var wins; try { wins = root.windows(); } catch(e){ wins = []; }
  for (var w = 0; w < wins.length && !found; w++) walk(wins[w], 0);
  return found;
}
function centerOf(el){
  try { var p = el.position(); var s = el.size();
    return Math.round(p[0] + s[0]/2) + "," + Math.round(p[1] + s[1]/2);
  } catch(e){ return ""; }
}

// ─── Main ───
function run(argv){
  try { main(argv); }
  catch (e){ console.log(typeof e === "string" ? e : ("ERR: " + e)); }
}

function main(argv){
  var app = argv[0], cmd = argv[1];
  if (!app || !cmd) die("ERR: usage: <app> <cmd> <args...>");

  // System Events process handle is needed only for AX commands; resolve it lazily so
  // pure coordinate commands stay independent of the (occasionally flaky) AX bridge.
  var _proc = null;
  function proc(){ if (!_proc) _proc = getProc(Application("System Events"), app); return _proc; }

  switch (cmd) {
    case "click": {
      var pid = getPid(app);
      postMouseClick(pid, parseFloat(argv[2]), parseFloat(argv[3]), argv[4] === "right", parseInt(argv[5]||"1", 10));
      console.log("ok"); break;
    }
    case "drag": {
      postDrag(getPid(app), parseFloat(argv[2]), parseFloat(argv[3]), parseFloat(argv[4]), parseFloat(argv[5]));
      console.log("ok"); break;
    }
    case "scroll": {
      postScroll(getPid(app), parseInt(argv[2]||"-3",10), parseInt(argv[3]||"0",10));
      console.log("ok"); break;
    }
    case "key": {
      var parts = String(argv[2]||"").toLowerCase().split("+");
      var keyName = parts[parts.length-1];
      var code = KC[keyName];
      if (code === undefined) die("ERR: unknown key: " + keyName);
      var flagMask = 0;
      for (var i = 0; i < parts.length-1; i++){ if (FLAGS[parts[i]]) flagMask = flagMask | FLAGS[parts[i]]; }
      postKeyCode(getPid(app), code, flagMask);
      console.log("ok"); break;
    }
    case "type": {
      // Background text entry: append to the focused text element's value via AX;
      // fall back to the first text element, then to best-effort key events.
      var text = argv.slice(2).join(" ");
      var roles = ["AXTextField","AXTextArea","AXSecureTextField","AXComboBox"];
      var target = findElPred(proc(), function(el){
        var r; try { r = el.role(); } catch(e){ return false; }
        if (roles.indexOf(r) < 0) return false;
        try { return el.focused() === true; } catch(e){ return false; }
      });
      if (!target) target = findEl(proc(), "name", "", roles); // first text element
      var done = false, tcenter = "";
      if (target){
        try { var c = ""; try { c = "" + (target.value()||""); } catch(e){}
          target.value = c + text;
          // Commit the value so SwiftUI / AppKit @State bindings update (they refresh on
          // confirm, not on a programmatic value write). Fully background — no key events.
          try { target.actions.byName("AXConfirm").perform(); } catch(e){}
          done = true; tcenter = centerOf(target); } catch(e){}
      }
      if (!done) postChars(getPid(app), text);
      // Report the field center (when known) so the caller can place the typing badge.
      console.log(tcenter ? ("center=" + tcenter) : "ok"); break;
    }
    case "press": {
      var el = findEl(proc(), argv[2], argv[3],
        ["AXButton","AXMenuItem","AXMenuButton","AXPopUpButton","AXCheckBox","AXRadioButton","AXLink","AXImage","AXCell","AXRow","AXStaticText"]);
      if (!el) die("ERR: element not found: " + argv[2] + "='" + argv[3] + "'");
      var center = centerOf(el);
      var pressed = false;
      try { el.actions.byName("AXPress").perform(); pressed = true; } catch(e){}
      if (!pressed){ try { el.click(); pressed = true; } catch(e){} }
      if (!pressed) die("ERR: AXPress failed");
      console.log("center=" + center); break;
    }
    case "settext": {
      var el2 = findEl(proc(), argv[2], argv[3],
        ["AXTextField","AXTextArea","AXSecureTextField","AXComboBox"]);
      if (!el2) die("ERR: text element not found: " + argv[2] + "='" + argv[3] + "'");
      var center2 = centerOf(el2);
      try { el2.value = argv.slice(4).join(" ");
        try { el2.actions.byName("AXConfirm").perform(); } catch(e){}  // commit to bindings
      } catch(e){ die("ERR: set value failed: " + e); }
      console.log("center=" + center2); break;
    }
    case "axcenter": {
      var el3 = findEl(proc(), argv[2], argv[3], null);
      if (!el3) die("ERR: element not found");
      console.log(centerOf(el3)); break;
    }
    default:
      die("ERR: unknown cmd: " + cmd);
  }
}
