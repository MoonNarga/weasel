// No dependencies: node --test tools/background-preview.test.cjs
// Exercises the actual inline script with a minimal DOM/canvas recording stub.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, 'background-preview.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function setup() {
  const elements = new Map();
  const draws = [];
  const ctx = new Proxy({drawImage: (...args) => draws.push(args), measureText: text => ({width: text.length * 8})}, {
    get(target, key) { return target[key] ?? (() => {}); }
  });
  function element(tag = 'div') {
    return {tag, value:'', checked:false, width:1000, height:400, style:{},
      classList:{toggle(){},add(){},remove(){}}, listeners:{},
      addEventListener(event, fn){this.listeners[event]=fn;},
      append(...children){for(const child of children)if(child.id)elements.set(child.id,child);},
      getContext(){return ctx;}, focus(){}, select(){}, click(){},
      getBoundingClientRect(){return {left:0,top:0,width:1000,height:400};},setPointerCapture(){}};
  }
  const document = {getElementById(id){if(!elements.has(id))elements.set(id,element());return elements.get(id);},
    createElement:element,querySelectorAll:()=>[]};
  for(const [key,value] of Object.entries({dpi:'96',backColor:'#ffffff',imagePath:'backgrounds/example.png',dragLine:'auto'}))document.getElementById(key).value=value;
  document.getElementById('showText').checked=true;
  const sandbox=vm.createContext({document,console,Math,Number,JSON,Blob,URL,setTimeout,navigator:{}});
  vm.runInContext(script,sandbox);
  return {elements,draws,run:code=>vm.runInContext(code,sandbox)};
}
const plain = value => JSON.parse(JSON.stringify(value));

test('current image boundaries at 96 DPI and 192 DPI',()=>{
  const app=setup();
  const g=plain(app.run('geometry(2172,724,{left:880,right:8,top:712,bottom:4,scale:12,width:660,height:88},96)'));
  assert.deepEqual(g.sx,[0,880,2164,2172]);
  assert.deepEqual(g.sy,[0,712,720,724]);
  assert.deepEqual(g.dx,[0,106,659,660]);
  assert.deepEqual(g.dy,[0,85,88,88]);
  const hi=plain(app.run('geometry(2172,724,{left:880,right:8,top:712,bottom:4,scale:12,width:660,height:88},192)'));
  assert.deepEqual(hi.dx,[0,211,1318,1320]);
  assert.deepEqual(hi.dy,[0,171,175,176]);
});

test('small windows shrink uniformly; boundaries remain ordered',()=>{
  const app=setup();
  for(const width of [1,8,50,660])for(const height of [1,10,88,300]){
    const g=plain(app.run(`geometry(2172,724,{left:880,right:8,top:712,bottom:4,scale:12,width:${width},height:${height}},144)`));
    assert.ok(g.actual<=.18+1e-12);
    for(const axis of [g.dx,g.dy])for(let i=1;i<4;i++)assert.ok(axis[i]>=axis[i-1]);
  }
});

test('invalid slices and runtime limits disable export instead of drawing stale output',()=>{
  const app=setup();
  for(const change of ['state.left=1200','state.top=500','state.scale=401','state.padding_left=2001','state.left=NaN']){
    app.run('demo()');app.run(change);app.run('render()');
    assert.equal(app.elements.get('saveYaml').disabled,true);
    assert.equal(app.elements.get('savePng').disabled,true);
    assert.equal(app.elements.get('yaml').value,'');
  }
});

test('zero borders render only the center tile; nine nonzero tiles cover target',()=>{
  const app=setup();app.run('state.left=state.right=state.top=state.bottom=0');
  app.draws.length=0;app.run('drawPreview(geometry(1200,500,state,96))');
  assert.equal(app.draws.length,1);
  assert.deepEqual(app.draws[0].slice(1),[0,0,1200,500,0,0,660,110]);
  app.run('demo()');app.draws.length=0;app.run('drawPreview(geometry(1200,500,state,96))');
  assert.equal(app.draws.length,9);
  assert.equal(app.draws.reduce((sum,a)=>sum+a[7]*a[8],0),660*110);
});

test('YAML round trip preserves escaped image paths and parameters',()=>{
  const app=setup();app.elements.get('imagePath').value='backgrounds/a "quoted" #图.png';
  const exported=app.run('yaml()');const imported=plain(app.run('parseConfig(yaml())'));
  assert.equal(imported.imagePath,app.elements.get('imagePath').value);
  assert.equal(imported.values.left,400);
  assert.equal(imported.values.radius,12);
  assert.ok(!exported.includes('min_width'));
});

test('nested config ignores unrelated fields; flat slice paths and comments work',()=>{
  const app=setup();
  const config='patch:\n  "style/background":\n    left: 880 # edge\n    scale: 12\n    image: \'backgrounds/it\'\'s.png\'\n  "preset_color_schemes/test":\n    left: 999\n  "style/background/top": 712\n  "style/layout/corner_radius": 6\n';
  const result=plain(app.run(`parseConfig(${JSON.stringify(config)})`));
  assert.deepEqual(result.values,{left:880,scale:12,top:712,radius:6});
  assert.equal(result.imagePath,"backgrounds/it's.png");
  assert.throws(()=>app.run('parseConfig("unrelated: true")'),/未识别/);
});

test('dragging a chosen cut line clamps at the other border',()=>{
  const app=setup();app.run('dragging="left";moveLine({clientX:9999,clientY:0})');
  assert.equal(app.run('state.left'),1187);
  assert.equal(app.run('validation()'),'');
});
