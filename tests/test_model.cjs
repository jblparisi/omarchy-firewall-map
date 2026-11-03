const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname,'../Model.js'),'utf8'),model);
const summary = {
  locations: [
    {id:'192.168.50.1',local:true,lat:1,lon:1},
    {id:'8.8.8.8',local:false,lat:2,lon:2,city:'Same city'},
    {id:'8.8.4.4',local:false,lat:2,lon:2,city:'Same city'}],
  hostnames:{'8.8.8.8':'dns.google'},
  flows:[
    {origin:'192.168.50.1',dest:'8.8.8.8',rate:100,rate_in:80,rate_out:20,inside:[{ip:'192.168.50.2',name:'Laptop',interface:'LAN'}]},
    {origin:'192.168.50.1',dest:'8.8.4.4',rate:500,inside:[{ip:'192.168.50.3'}]},
    {origin:'8.8.8.8',dest:'192.168.50.1',initiated:'remote',rate:200,inside:[{ip:'192.168.50.2',name:'Laptop'}]}
  ]
};
assert.equal(model.buildArcs(summary).length,2); // same-location outbound arcs merge on map
const remote = model.topTalkers(summary,4,'remote');
assert.equal(remote.length,2); // host cards must never merge those IPs
assert.equal(remote[0].ip,'8.8.4.4');
assert.equal(remote[0].rate,500);
assert.equal(remote[1].rate,300); // incoming connection belongs to remote origin
assert.equal(remote[1].label,'dns.google');
const local = model.topTalkers(summary,4,'local');
assert.equal(local.length,2);
assert.equal(local[1].ip,'192.168.50.2');
assert.equal(local[1].name,'Laptop');
assert.equal(local[1].rate,300);
assert.equal(local[1].rateIn,80);
assert.equal(local[1].flows,2);
assert.equal(model.topTalkers({flows:[]},4,'remote').length,0);
const markup = '<img src="https://example.invalid/tracker">';
summary.hostnames['8.8.8.8']=markup;
assert.equal(model.topTalkers(summary,4,'remote')[1].label,markup); // rendered as PlainText
assert(!model.tooltipText(markup).includes('<'));
assert(!model.tooltipText('Error: <b>offline</b>').includes('<'));
const config = {bar:{layout:{right:[{id:model.PLUGIN_ID,interval:1,showHostnames:true}]}}};
assert.equal(model.pluginSettings(config,model.PLUGIN_ID).interval,1);
assert.equal(model.pluginSettings(config,model.PLUGIN_ID).showHostnames,true);
console.log('Model tests passed: exact host ranking, inbound direction, LAN labels, rates, empty data, markup safety');
const arcs = model.buildArcs(summary);
const merged = arcs.find(arc => arc.members === 2);
assert(merged);
const mapHosts = model.hostsForArcs(summary,[merged]);
assert.equal(mapHosts.length,2);
assert.equal(mapHosts[0].ip,'8.8.4.4');
assert.equal(mapHosts[1].ip,'8.8.8.8');
const allDirections = model.hostsForArcs(summary,arcs);
assert.equal(allDirections.length,2);
assert.equal(allDirections.find(host => host.ip === '8.8.8.8').rate,300);
const refreshed = model.refreshMapHosts(summary,mapHosts,'remote');
assert.equal(refreshed.find(host => host.ip === '8.8.8.8').rate,300);
const vanished = model.refreshMapHosts({flows:[]},mapHosts,'remote');
assert.equal(vanished[0].ip,mapHosts[0].ip);
assert.equal(vanished[0].rate,0);
const blockSummary = {hostnames:{'2606:4700:4700::1111':'resolver.example'},
  blocks:[{source:'2606:4700:4700::1111',hits:12,hits_per_minute:6}]};
const blockHosts = model.hostsForBlocks(blockSummary,blockSummary.blocks);
assert.equal(blockHosts[0].label,'resolver.example');
assert.equal(blockHosts[0].ip,'2606:4700:4700::1111');
assert.equal(blockHosts[0].hits,12);
assert.equal(model.refreshMapHosts(blockSummary,blockHosts,'blocked')[0].hits,12);
assert.equal(model.segmentDistance(50,3,{x:0,y:0},{x:100,y:0}),3);
assert.equal(model.segmentDistance(103,4,{x:0,y:0},{x:100,y:0}),5);
assert.equal(model.segmentDistance(3,4,{x:0,y:0},{x:0,y:0}),5);
console.log('Map model tests passed: co-located IP choices, inbound hosts, live selection rates, disappeared hosts, IPv6 block sources, line picking');

const threatSummary = {
  locations: [{id:'home',local:true,lat:40,lon:-70}],
  hostnames: {'203.0.113.1':'flagged.example'},
  flows: Array.from({length:6}, (_,i) => ({origin:'home',dest:'203.0.113.'+(i+1),
    rate:100+i,threat:true})).concat([
      {origin:'home',dest:'198.51.100.1',rate:10000},
      {origin:'home',dest:'203.0.113.1',rate:5000,threat:false},
      {origin:'203.0.113.1',dest:'home',initiated:'remote',rate:50,threat:true}
    ])
};
const threats = model.topTalkers(threatSummary,threatSummary.flows.length,'threats');
assert.equal(threats.length,6); // all flagged hosts remain available in the scrolling list
assert(!threats.some(host => host.ip === '198.51.100.1'));
const flagged = threats.find(host => host.ip === '203.0.113.1');
assert.equal(flagged.label,'flagged.example');
assert.equal(flagged.rate,150); // only threat flows, including remotely initiated flows
assert.equal(flagged.flows,2);
assert(threats.every(host => host.threat));
assert.equal(model.topTalkers({flows:[]},1,'threats').length,0);
assert.equal(model.topTalkers({flows:[{origin:'home',dest:'safe',rate:10}]},1,'threats').length,0);
console.log('Threat list tests passed: filtering, all hosts, inbound flows, names, empty samples');
