// SmartPowerSwitch setup page (served by the ESP32 at http://192.168.4.1)
// Kept in this .h file on purpose: the Arduino IDE rewrites .ino files before
// compiling and was injecting code INTO this page when it lived in the .ino,
// which broke the page's JavaScript. Keep this file next to the .ino.
//
// {{ID}} and {{AP}} are replaced at send time.

#pragma once
#include <Arduino.h>

static const char PORTAL_HTML[] PROGMEM = R"rawliteral(<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SmartSwitch Wi-Fi setup</title>
<style>
:root{--a:#1a5c35;--ink:#0e2e1a;--mid:#24402e;--mut:#3a5344;--ln:#dcebe1;--g:16px}
*{box-sizing:border-box}
body{margin:0;background:#fff;color:var(--ink);font:15px/22px Roboto,system-ui,-apple-system,"Segoe UI",sans-serif;font-variant-numeric:tabular-nums}
button,input{font:inherit;color:inherit}button{cursor:pointer;background:none;border:0;padding:0}
:focus-visible{outline:3px solid #6ecb8a;outline-offset:2px}[hidden]{display:none!important}
svg{width:20px;height:20px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}
header{border-bottom:1px solid var(--ln);padding:12px var(--g) 14px}
.w{max-width:1040px;margin:0 auto}
.hd{display:flex;align-items:center;gap:4px;min-height:48px}.hd h1{margin:0;font-size:24px;line-height:30px;flex:1}
.ib{width:48px;height:48px;margin-left:-12px;display:flex;align-items:center;justify-content:center}.ib svg{width:24px;height:24px}
.dev{display:none;align-items:center;gap:12px;font-size:14px;line-height:20px;color:var(--mid)}
.cap{font-size:13px;line-height:18px;font-weight:500;color:var(--mut)}
.bar{display:flex;gap:6px;margin-top:8px}.bar i{flex:1;height:3px;border-radius:9px;background:var(--ln)}.bar i.on{background:var(--a)}
.pill{font-size:12px;line-height:16px;font-weight:600;padding:4px 10px;border-radius:99px;color:#a15208;background:#fdf1e2;white-space:nowrap}
.pill.ok{color:#1f7a40;background:#e6f5eb}
main{padding-bottom:24px}.side{display:none}
.li{display:flex;align-items:center;gap:12px;width:100%;padding-left:var(--g);text-align:left;background:#fff}
.ct{flex:1;min-width:0;min-height:64px;display:flex;align-items:center;gap:8px;padding-right:var(--g);border-bottom:1px solid var(--ln)}
.ct.nb{border-bottom:0}
.tx{flex:1;min-width:0;display:flex;flex-direction:column}
.tx b,.add b{font-size:16px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tx small{font-size:14px;line-height:20px;color:var(--mid);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ic{width:40px;height:40px;border:1px solid var(--ln);border-radius:12px;display:flex;align-items:center;justify-content:center;color:var(--a);flex:none}
.li[disabled]{cursor:default}.li[disabled] .ic{color:#9aaea1}
.add{color:var(--a)}
.sm{width:18px;height:18px;color:var(--mid)}
.dvr,.nr{padding:16px var(--g);display:flex;align-items:center;gap:12px;border-bottom:1px solid var(--ln)}
.nr h2{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sh{padding:28px var(--g) 4px;display:flex;align-items:center;justify-content:space-between;gap:8px}
h2{margin:0;font-size:18px;line-height:24px;font-weight:700}
.tb{height:48px;padding-left:12px;color:var(--a);font-size:14px;font-weight:600;display:flex;align-items:center;gap:6px}
.empty{padding:16px var(--g);color:var(--mid)}
.frm{padding:24px var(--g) 0;display:flex;flex-direction:column;gap:20px}
label{display:block;font-size:14px;line-height:20px;font-weight:600;margin-bottom:6px}
.fld{display:flex;align-items:center;height:52px;border:1px solid #51685a;border-radius:12px;padding-left:14px}.fld.bad{border-color:#b42318}
.fld:focus-within{outline:3px solid #6ecb8a;outline-offset:2px}
.fld input{flex:1;min-width:0;height:100%;border:0;background:none;outline:none;padding-right:14px}
input::placeholder{color:#51685a}
.eye{width:48px;height:48px;display:flex;align-items:center;justify-content:center;color:var(--mid);flex:none}
.hint{display:block;margin-top:6px;font-size:13px;line-height:18px;font-weight:500;color:var(--mut)}
.err{background:#fdecea;color:#b42318;border-radius:12px;padding:12px;display:flex;gap:10px;font-size:14px;line-height:20px}
.btn{height:48px;border-radius:12px;background:var(--a);color:#fff;font-weight:600;padding:0 24px}.btn:disabled{background:#9aaea1;cursor:default}
.ctr{padding:40px var(--g) 0;display:flex;flex-direction:column;align-items:center;gap:16px;text-align:center}
.ctr h2{font-size:22px;line-height:28px}.ctr p{margin:4px 0 0;color:var(--mid)}
.spin{width:56px;height:56px;border-radius:50%;border:4px solid var(--ln);border-top-color:var(--a);animation:r .9s linear infinite;flex:none}
.spin.s{width:22px;height:22px;border-width:3px}.rot{animation:r .9s linear infinite}
@keyframes r{to{transform:rotate(360deg)}}
.lst{margin-top:32px;border-top:1px solid var(--ln)}
.sr{display:flex;align-items:center;gap:16px;padding-left:var(--g)}.sr .ct{min-height:56px}
.dot{width:24px;height:24px;display:flex;align-items:center;justify-content:center;flex:none}
.dn{width:24px;height:24px;border-radius:50%;background:#1f7a40;color:#fff;display:flex;align-items:center;justify-content:center}.dn svg{width:14px;height:14px;stroke-width:3}
.pd{width:22px;height:22px;border-radius:50%;border:2px solid #9aaea1}
.chk{width:64px;height:64px;border-radius:50%;border:2px solid #1f7a40;color:#1f7a40;display:flex;align-items:center;justify-content:center;flex:none}
.chk svg{width:32px;height:32px;stroke-width:2.5}.chk.wr{border-color:#a15208;color:#a15208}
.kv{min-height:52px;padding:0 var(--g);border-bottom:1px solid var(--ln);display:flex;align-items:center;justify-content:space-between;gap:12px}
.kv span{font-size:14px;color:var(--mid)}.kv b{font-weight:600;text-align:right;overflow-wrap:anywhere}
.note{margin:20px var(--g) 0;border:1px solid var(--ln);border-radius:12px;padding:12px 14px;display:flex;gap:10px;font-size:14px;line-height:20px}.note svg{color:var(--a)}
.side ol{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:4px}
.side li{min-height:48px;display:flex;align-items:center;gap:12px;color:var(--mut);font-weight:500}
.side li i{width:28px;height:28px;border-radius:50%;border:1.5px solid #9aaea1;display:flex;align-items:center;justify-content:center;font-style:normal;font-size:14px;font-weight:700}
.side li.cur{color:var(--ink);font-weight:700}.side li.ok2{color:var(--ink)}
.side li.cur i,.side li.ok2 i{border-color:var(--a);color:var(--a)}
@media(min-width:900px){
:root{--g:0px}header{padding:16px 24px}
.dev{display:flex}.mob,.dvr{display:none}
main{display:grid;grid-template-columns:240px minmax(0,1fr);gap:64px;padding:40px 24px 48px}
.side{display:block}.sh{padding-top:0}.sh h2,.nr h2{font-size:22px;line-height:28px}
.nr{padding-top:0}.frm{max-width:460px}.btn{align-self:flex-start;min-width:160px}
.ctr{flex-direction:row;text-align:left;padding-top:0}.note{margin-left:0;margin-right:0}
}
</style></head><body>
<header><div class="w hd">
<button class="ib" id="bk" aria-label="Back to networks" hidden><svg viewBox="0 0 24 24"><path d="M19 12H5M12 19l-7-7 7-7"/></svg></button>
<h1>Wi-Fi setup</h1>
<div class="dev">SmartSwitch &middot; {{ID}} <span class="pill" id="pl">Setup mode</span></div>
</div>
<div class="w mob"><div class="cap" id="stp">Step 1 of 3</div><div class="bar"><i class="on"></i><i id="b2"></i><i id="b3"></i></div></div>
</header>
<main class="w">
<nav class="side" aria-label="Setup steps"><ol><li id="n1"><i>1</i>Choose network</li><li id="n2"><i>2</i>Enter password</li><li id="n3"><i>3</i>Connect</li></ol></nav>
<section>

<div id="s1">
<div class="dvr"><span class="ic"><svg viewBox="0 0 24 24"><path d="M9 2v6M15 2v6M6 8h12v4a6 6 0 0 1-12 0V8zM12 18v4"/></svg></span>
<span class="tx"><b>SmartSwitch</b><small>ID {{ID}}</small></span><span class="pill">Setup mode</span></div>
<div class="sh"><h2>Choose a network</h2><button class="tb" id="rs"><svg id="rsi" viewBox="0 0 24 24"><path d="M21 12a9 9 0 1 1-3-6.7M21 3v6h-6"/></svg><span id="rsl">Rescan</span></button></div>
<div id="list"><div class="empty">Scanning&hellip;</div></div>
<button class="li add" id="hid"><span class="ic"><svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg></span><span class="ct nb"><b>Enter a hidden network</b></span></button>
</div>

<div id="s2" hidden>
<div class="nr" id="nr"><span class="ic"><svg viewBox="0 0 24 24"><path d="M2 8.5a15 15 0 0 1 20 0M5 12a10 10 0 0 1 14 0M8.5 15.5a5 5 0 0 1 7 0"/><circle cx="12" cy="19" r="1.2" fill="currentColor" stroke="none"/></svg></span><h2 id="nm"></h2></div>
<form class="frm" id="fm" autocomplete="off">
<div id="mw" hidden><label for="ss">Network name (SSID)</label><div class="fld"><input id="ss" maxlength="32" autocapitalize="none" spellcheck="false" placeholder="e.g. DNSC-IoT"></div></div>
<div><label for="pw">Wi-Fi password</label>
<div class="fld" id="pf"><input id="pw" type="password" maxlength="63" autocapitalize="none" spellcheck="false" placeholder="Enter password">
<button type="button" class="eye" id="ey" aria-label="Show password"></button></div>
<span class="hint">At least 8 characters</span></div>
<div class="err" id="er" role="alert" hidden><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/></svg><span id="et"></span></div>
<button class="btn" id="go" disabled>Connect</button>
</form>
</div>

<div id="s3" hidden>
<div class="ctr"><div class="spin"></div><div><h2 id="ct"></h2><p>Keep this page open</p></div></div>
<div class="lst"><div class="sr"><span class="dot" id="d1"></span><span class="ct">Sending details</span></div>
<div class="sr"><span class="dot" id="d2"></span><span class="ct" id="j2"></span></div></div>
</div>

<div id="s4" hidden>
<div class="ctr"><div class="chk"><svg viewBox="0 0 24 24"><path d="m5 12 5 5 9-10"/></svg></div><div><h2>Connected</h2><p id="okm"></p></div></div>
<div class="lst"><div class="kv"><span>Network</span><b id="kn"></b></div><div class="kv"><span>IP address</span><b id="ki"></b></div><div class="kv"><span>Device ID</span><b>{{ID}}</b></div></div>
<div class="note"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/></svg><span>Reconnect your phone to your usual Wi-Fi.</span></div>
</div>

<div id="s5" hidden>
<div class="ctr"><div class="chk wr"><svg viewBox="0 0 24 24"><path d="M12 8v5M12 16h.01"/><circle cx="12" cy="12" r="9"/></svg></div>
<div><h2>Lost connection</h2><p>If {{AP}} is gone from your Wi-Fi list, setup worked. If not, rejoin it and try again.</p></div></div>
<div class="frm"><button class="btn" type="button" onclick="location.reload()">Try again</button></div>
</div>

</section></main>
<script>
var $=function(i){return document.getElementById(i)},S={ssid:'',man:false},nets=[],fails=0,tm;
var EYE='<svg viewBox="0 0 24 24"><path d="M2 12s4-6 10-6 10 6 10 6-4 6-10 6S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>';
var EYEX='<svg viewBox="0 0 24 24"><path d="M3 3l18 18M10.6 6.1A10 10 0 0 1 12 6c6 0 10 6 10 6a17 17 0 0 1-3.2 3.6M6.6 6.6A17 17 0 0 0 2 12s4 6 10 6a9.7 9.7 0 0 0 5.4-1.6M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>';
var LOCK='<svg class="sm" viewBox="0 0 24 24" aria-label="Secured"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>';
var CHEV='<svg class="sm" viewBox="0 0 24 24"><path d="m9 6 6 6-6 6"/></svg>';
var DONE='<span class="dn"><svg viewBox="0 0 24 24"><path d="m5 12 5 5 9-10"/></svg></span>';
function wifi(l){function o(n){return l>=n?1:.25}return'<svg viewBox="0 0 24 24"><path opacity="'+o(3)+'" d="M2 8.5a15 15 0 0 1 20 0"/><path opacity="'+o(2)+'" d="M5 12a10 10 0 0 1 14 0"/><path d="M8.5 15.5a5 5 0 0 1 7 0"/><circle cx="12" cy="19" r="1.2" fill="currentColor" stroke="none"/></svg>'}
function esc(s){return String(s).replace(/[&<>"']/g,function(c){return'&#'+c.charCodeAt(0)+';'})}
function show(n){
for(var i=1;i<6;i++)$('s'+i).hidden=i!=n;
var k=n<2?1:n==2?2:3,done=n==4;
$('stp').textContent='Step '+k+' of 3';$('b2').className=k>1?'on':'';$('b3').className=k>2?'on':'';
for(i=1;i<4;i++){var li=$('n'+i),d=i<k||done;li.className=d?'ok2':i==k?'cur':'';li.firstChild.textContent=d?'✓':i}
$('bk').hidden=n!=2;$('pl').textContent=done?'Online':'Setup mode';$('pl').className=done?'pill ok':'pill';
}
var t0=0;
function get(u){var c=window.AbortController?new AbortController():null,t=setTimeout(function(){if(c)c.abort()},6000);
return fetch(u,{cache:'no-store',signal:c?c.signal:undefined}).then(function(x){clearTimeout(t);return x.json()},function(e){clearTimeout(t);throw e})}
function scan(r){
if(r||!t0)t0=Date.now();
$('rsl').textContent='Scanning…';$('rsi').classList.add('rot');
function late(){return Date.now()-t0>25000}
get('/scan'+(r?'?refresh=1':'')).then(function(d){
if(d.scanning&&!late()){tm=setTimeout(scan,1000);return}t0=0;if(!d.scanning)nets=d.networks||[];render()
}).catch(function(){if(late()){t0=0;render();return}tm=setTimeout(scan,1500)})}
function render(){
$('rsl').textContent='Rescan';$('rsi').classList.remove('rot');
if(!nets.length){$('list').innerHTML='<div class="empty">No networks found</div>';return}
$('list').innerHTML=nets.map(function(n,i){
var l=n.rssi>-60?3:n.rssi>-75?2:1,m=n.ent?'Enterprise &middot; not supported':(n.secure?'Secured':'Open')+' &middot; '+['','Weak','Good','Strong'][l];
return'<button class="li" data-i="'+i+'"'+(n.ent?' disabled':'')+'><span class="ic">'+wifi(l)+'</span><span class="ct"><span class="tx"><b>'+esc(n.ssid)+'</b><small>'+m+'</small></span>'+(n.secure?LOCK:'')+(n.ent?'':CHEV)+'</span></button>'}).join('')}
$('list').onclick=function(e){var b=e.target.closest('button');if(!b||b.disabled)return;var n=nets[+b.dataset.i];
S.ssid=n.ssid;S.man=false;if(!n.secure){connect('');return}form()};
function form(err){
$('mw').hidden=!S.man;$('nr').hidden=S.man;$('nm').textContent=S.ssid;
if(!err)$('pw').value='';$('er').hidden=!err;$('pf').className=err?'fld bad':'fld';if(err)$('et').textContent=err;
valid();show(2);(S.man&&!$('ss').value?$('ss'):$('pw')).focus()}
function valid(){$('go').disabled=$('pw').value.length<8||(S.man&&!$('ss').value.trim())}
$('pw').oninput=$('ss').oninput=function(){$('er').hidden=true;$('pf').className='fld';valid()};
$('ey').innerHTML=EYE;
$('ey').onclick=function(){var p=$('pw'),s=p.type=='password';p.type=s?'text':'password';this.setAttribute('aria-label',s?'Hide password':'Show password');this.innerHTML=s?EYEX:EYE};
$('fm').onsubmit=function(e){e.preventDefault();if($('go').disabled)return;if(S.man)S.ssid=$('ss').value.trim();connect($('pw').value)};
$('hid').onclick=function(){S.man=true;S.ssid='';$('ss').value='';form()};
$('bk').onclick=function(){show(1)};
$('rs').onclick=function(){clearTimeout(tm);scan(1)};
function connect(p){
$('ct').textContent='Connecting to '+S.ssid;$('j2').textContent='Joining '+S.ssid;
$('d1').innerHTML='<span class="spin s"></span>';$('d2').innerHTML='<span class="pd"></span>';show(3);fails=0;
fetch('/connect',{method:'POST',body:new URLSearchParams({ssid:S.ssid,pass:p})}).then(function(x){if(!x.ok)throw 0;
$('d1').innerHTML=DONE;$('d2').innerHTML='<span class="spin s"></span>';setTimeout(poll,1500)}).catch(function(){form("Couldn't reach SmartSwitch. Try again.")})}
function poll(){
get('/status').then(function(d){fails=0;
if(d.state=='connected'){$('d2').innerHTML=DONE;$('okm').textContent='SmartSwitch is online on '+S.ssid+'.';$('kn').textContent=S.ssid;$('ki').textContent=d.ip||'';show(4);return}
if(d.state=='failed'){form(d.reason=='auth'?'Wrong password for '+S.ssid+'.':d.reason=='notfound'?"Can't find "+S.ssid+'. Move closer and try again.':"Couldn't join "+S.ssid+'. Try again.');return}
setTimeout(poll,1000)}).catch(function(){if(++fails>20){show(5);return}setTimeout(poll,1000)})}
show(1);scan();
</script>
</body></html>)rawliteral";
