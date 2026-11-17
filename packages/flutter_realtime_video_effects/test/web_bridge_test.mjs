import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const neutralRuntime = await readFile(new URL('../../flutter_realtime_processed_video/web/processed-video-bridge.js', import.meta.url), 'utf8');
const runtime = await readFile(new URL('../web/video-effects-bridge.js', import.meta.url), 'utf8');
function harness({videoSize = [640, 360], model, mask = null, faces = [], imageSize = [1920,1080]} = {}) {
  const calls = [], cameras = [], videos = [], images = [], mattes = [];
  let sequence = 0, frameTime = 0;
  const output = {id:'processed', enabled:true, stop(){calls.push('output.stop');}, requestFrame(){}};
  function makeVideo() {
    const listeners = new Map();
    const video = {style:{}, readyState:2, videoWidth:videoSize[0], videoHeight:videoSize[1],
      addEventListener(name, callback){listeners.set(name, callback);},
      removeEventListener(name){listeners.delete(name);},
      dispatch(name){listeners.get(name)?.();}, srcObject:null, async play(){}, pause(){},
      requestVideoFrameCallback(cb){this.callback=(now = (frameTime += 50), metadata = {mediaTime:now/1000})=>cb(now,metadata);return 1;}, cancelVideoFrameCallback(){this.callback=null;}};
    videos.push(video); return video;
  }
  const context = vm.createContext({console, URL, Blob, setTimeout, clearTimeout, performance:{now:()=>100},
    MediaStream:class {constructor(tracks){this.tracks=tracks;}},
    ImageData:class {constructor(data,width,height){Object.assign(this,{data,width,height});}},
    navigator:{mediaDevices:{async getUserMedia(constraints){
      calls.push(['camera.open',constraints]);
      const track = {enabled:true,id:`camera-${++sequence}`,stop(){calls.push(`${this.id}.stop`);},
        getSettings(){return {width:640,height:360,frameRate:24,deviceId:constraints.video.deviceId?.exact || 'default-camera'};}};
      cameras.push(track);return {getVideoTracks:()=>[track],getTracks:()=>[track]};
    }}},
    document:{baseURI:'http://localhost/',getElementById:()=>null,createElement(tag){
      if(tag==='video')return makeVideo();
      const canvas={width:0,height:0, getContext(){return {
        save(){},restore(){},clearRect(){},fillRect(){calls.push('blank');},
        drawImage(input){calls.push(input === videos[0] ? 'raw.draw' : 'composite.draw');},
        putImageData(image){mattes.push(image);},
      };},captureStream(){return {getVideoTracks:()=>[output]};}};return canvas;
    }},
    async createImageBitmap(){const image={width:imageSize[0],height:imageSize[1],close(){calls.push('image.close');}}; images.push(image);return image;},
    SdkVideoEffectsVision:{FaceDetector:{async createFromOptions(){return {detectForVideo(){calls.push('faces.detect');return {detections:faces};},close(){calls.push('faces.close');}};}},FilesetResolver:{async forVisionTasks(){return {}; }},
      ImageSegmenter:{async createFromOptions(){calls.push('model.create');
        if(model)return model();
        return {segmentForVideo(){return {confidenceMasks:mask?[mask]:[],close(){}};},close(){calls.push('model.close');}};
      }}},
    __flutterVideoEffectsOnError(id,error){calls.push(['error',id,error]);},
  });
  vm.runInContext(neutralRuntime,context);
  vm.runInContext(runtime,context);
  return {bridge:context.RealtimeVideoEffectsBridge,calls,cameras,videos,output,images,mattes};
}

test('preview binds the actual element before DOM insertion',async()=>{
  const h=harness(); const info=await h.bridge.createSource('one',{});
  assert.equal(info.width,640);assert.equal(info.height,360);assert.equal(info.cameraDeviceId,'default-camera');
  const element={style:{},querySelector:()=>null,replaceChildren(video){this.video=video;}};
  h.bridge.attachPreviewElement('one',element);
  assert.equal(element.video.srcObject.tracks[0],h.output);
  h.bridge.disposeSource('one');
  assert.ok(h.calls.includes('camera-1.stop'));assert.ok(h.calls.includes('output.stop'));
});

test('effect initialization failure never opens or publishes a camera',async()=>{
  const h=harness({model:()=>{throw new Error('model unavailable');}});
  await assert.rejects(h.bridge.createSource('one',{effect:{type:'blur'}}),/model unavailable/);
  assert.equal(h.cameras.length,0);
  assert.equal(h.calls.includes('raw.draw'),false);
});

test('switching from none suspends shared output during initialization and stays closed on failure',async()=>{
  let reject;
  const h=harness({model:()=>new Promise((_,r)=>{reject=r;})});
  await h.bridge.createSource('one',{});
  await h.videos[0].callback();
  const count=h.calls.filter(c=>c==='raw.draw').length;
  const change=h.bridge.setEffect('one',{type:'blur'});
  await h.videos[0].callback();
  assert.equal(h.calls.filter(c=>c==='raw.draw').length,count);
  assert.equal(h.output.enabled,false);
  // Allow the fileset Promise to settle before rejecting model creation.
  await new Promise(r=>setImmediate(r));reject(new Error('segmentation failed'));
  await assert.rejects(change,/segmentation failed/);
  assert.equal(h.output.enabled,false);assert.equal(h.cameras[0].enabled,false);
  assert.ok(h.calls.includes('blank'));
  await h.bridge.setEffect('one',{type:'none'});
  assert.equal(h.output.enabled,true);
  h.bridge.disposeSource('one');
});

test('camera switch preserves disabled state and one processed output',async()=>{
  const h=harness();await h.bridge.createSource('one',{});
  await h.bridge.setEnabled('one',false);
  await h.bridge.selectCamera('one','second-camera');
  assert.equal(h.cameras[1].enabled,false);assert.equal(h.output.enabled,false);
  assert.equal(h.bridge.getTrack('one'),h.output);
  assert.ok(h.calls.includes('camera-1.stop'));
  await h.bridge.setEnabled('one',true);assert.equal(h.cameras[1].enabled,true);
  h.bridge.disposeSource('one');h.bridge.disposeSource('one');
});

test('invalid decoded images are rejected and their bitmap is released',async()=>{
  const h=harness({imageSize:[5000,100]});await h.bridge.createSource('one',{});
  await assert.rejects(h.bridge.setEffect('one',{type:'replaceImage',imageBytes:[137]}),/4096/);
  assert.ok(h.calls.includes('image.close'));assert.equal(h.output.enabled,false);
  h.bridge.disposeSource('one');
});

test('matte keeps confident person sharp and feathers only uncertain outer edges',async()=>{
  const values=new Float32Array([0,0,0,0,0, 0,0.3,0.8,0.3,0, 0,0,0,0,0]);
  const h=harness({mask:{width:5,height:3,getAsFloat32Array:()=>values}});
  await h.bridge.createSource('one',{effect:{type:'blur'}});
  await h.videos[0].callback();const pixels=h.mattes[0].data;
  assert.equal(pixels[7*4+3],255);
  assert.ok(pixels[6*4+3]>Math.round(0.3*255));
  assert.ok(pixels[0*4+3]<16);
  h.bridge.disposeSource('one');
});


test('face protection preserves cheek pixels missed by person segmentation',async()=>{
  const mask={width:20,height:12,getAsFloat32Array:()=>new Float32Array(240)};
  const h=harness({mask,faces:[{boundingBox:{originX:200,originY:100,width:240,height:200}}]});
  await h.bridge.createSource('one',{effect:{type:'blur'}});await h.videos[0].callback();
  const pixels=h.mattes[0].data;
  assert.equal(pixels[(6*20+12)*4+3],255,'right cheek remains sharp');
  assert.equal(pixels[3],0,'background stays outside face protection');
  h.bridge.disposeSource('one');assert.ok(h.calls.includes('faces.close'));
});


test('24 fps pacing preserves its deadline with a 30 fps camera', async () => {
  const h=harness(); await h.bridge.createSource('one',{frameRate:24});
  h.calls.length=0; // Measure pacing after the initial readiness frame.
  for(let index=0;index<30;index++) await h.videos[0].callback(index*1000/30,{mediaTime:index/30});
  assert.equal(h.calls.filter(call=>call==='raw.draw').length,24);
  assert.equal(h.calls.includes('model.create'),false,'none never initializes segmentation');
  h.bridge.disposeSource('one');
});

test('camera callbacks do not render the same decoded frame twice', async () => {
  const h=harness(); await h.bridge.createSource('one',{frameRate:30});
  h.calls.length=0; // The source is already primed before callbacks begin.
  await h.videos[0].callback(0,{mediaTime:0});
  await h.videos[0].callback(40,{mediaTime:0});
  await h.videos[0].callback(80,{mediaTime:1/30});
  assert.equal(h.calls.filter(call=>call==='raw.draw').length,2);
  h.bridge.disposeSource('one');
});

test('Safari live camera callbacks advance on presentedFrames when mediaTime stays zero', async () => {
  const h=harness(); await h.bridge.createSource('one',{frameRate:30});
  h.calls.length=0;
  await h.videos[0].callback(0,{mediaTime:0,presentedFrames:1});
  await h.videos[0].callback(40,{mediaTime:0,presentedFrames:1});
  await h.videos[0].callback(80,{mediaTime:0,presentedFrames:2});
  await h.videos[0].callback(120,{mediaTime:0,presentedFrames:3});
  assert.equal(h.calls.filter(call=>call==='raw.draw').length,3);
  h.bridge.disposeSource('one');
});

test('face detection runs on first frame and throttles intermediate frames', async () => {
  const mask={width:8,height:8,getAsFloat32Array:()=>new Float32Array(64).fill(1)};
  const h=harness({mask});
  await h.bridge.createSource('one',{effect:{type:'blur'},frameRate:30});
  // Initial renderReadyFrame already ran face detection once (counter -> 1).
  assert.equal(h.calls.filter(c=>c==='faces.detect').length,1);
  for(let i=1;i<=5;i++) await h.videos[0].callback(i*40,{mediaTime:i/30,presentedFrames:i});
  assert.equal(h.calls.filter(c=>c==='faces.detect').length,2);
  h.bridge.disposeSource('one');
});

test('steady mask dimensions reuse the same matte allocation', async () => {
  const mask={width:4,height:4,getAsFloat32Array:()=>new Float32Array(16).fill(1)};
  const h=harness({mask}); await h.bridge.createSource('one',{effect:{type:'blur'}});
  h.mattes.length=0;
  await h.videos[0].callback(100,{mediaTime:0.1});
  await h.videos[0].callback(150,{mediaTime:0.15});
  assert.equal(h.mattes.length,2); assert.strictEqual(h.mattes[0],h.mattes[1]);
  h.bridge.disposeSource('one');
});


test('creation waits for decoded video dimensions before handing a track to a publisher', async () => {
  const h=harness({videoSize:[0,0]});
  let ready=false;
  const creating=h.bridge.createSource('one',{}).then(()=>{ready=true;});
  await new Promise(r=>setImmediate(r));
  assert.equal(ready,false);
  assert.equal(h.calls.includes('raw.draw'),false);
  h.videos[0].videoWidth=640; h.videos[0].videoHeight=360;
  h.videos[0].dispatch('loadeddata');
  await creating;
  assert.equal(h.calls.includes('raw.draw'),true);
  h.bridge.disposeSource('one');
});

test('first inference failure rejects creation and releases the camera', async () => {
  const h=harness({model:()=>({segmentForVideo(){throw new Error('inference failed');},close(){}})});
  await assert.rejects(h.bridge.createSource('one',{effect:{type:'blur'}}),/inference failed/);
  assert.ok(h.calls.includes('camera-1.stop'));
  assert.ok(h.calls.includes('output.stop'));
});

test('runtime failure rejects camera re-enable until an explicit effect reset succeeds', async () => {
  let broken=false;
  const h=harness({model:()=>({segmentForVideo(){if(broken)throw new Error('GPU lost');return {};},close(){}})});
  await h.bridge.createSource('one',{effect:{type:'blur'}});
  broken=true;
  await h.videos[0].callback();
  assert.equal(h.output.enabled,false);
  await assert.rejects(h.bridge.setEnabled('one',true),/GPU lost/);
  await h.bridge.setEffect('one',{type:'none'});
  await h.bridge.setEnabled('one',true);
  assert.equal(h.output.enabled,true);
  h.bridge.disposeSource('one');
});

test('switching effects rejects when the first protected frame cannot be processed', async () => {
  const h=harness({model:()=>({segmentForVideo(){throw new Error('first frame failed');},close(){}})});
  await h.bridge.createSource('one',{});
  await assert.rejects(h.bridge.setEffect('one',{type:'blur'}),/first frame failed/);
  assert.equal(h.output.enabled,false);
  h.bridge.disposeSource('one');
});
