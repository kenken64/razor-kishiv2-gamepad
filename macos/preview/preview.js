import * as THREE from "three";
import {GLTFLoader} from "three/addons/loaders/GLTFLoader.js";
import {CharacterRig,ease} from "./rig.js";

const $=selector=>document.querySelector(selector);
const stage=$("#stage"), menu=$("#models"), status=$("output");
const send=(action,extras={})=>window.webkit.messageHandlers.characters.postMessage({action,...extras});
const v=(x=0,y=0,z=0)=>new THREE.Vector3(x,y,z);
const clamp=THREE.MathUtils.clamp;
const chinese={"Sun Wukong":"孙悟空","Zhu Bajie":"猪八戒","Sha Seng":"沙僧","Tang Seng":"唐僧","Bull Demon King":"牛魔王","Princess Iron Fan":"铁扇公主"};
function nameOf(file){return file.replace(/\.glb$/i,"").replace(/[ _-]+rigged$/i,"").replace(/[ _)\-]+/g," ").trim().replace(/^Tang Jeng$/i,"Tang Seng");}

const scene=new THREE.Scene();
scene.background=new THREE.Color(0x15212d);
scene.fog=new THREE.FogExp2(0x15212d,.037);
const camera=new THREE.PerspectiveCamera(38,1,.05,90);
let renderer;
try { renderer=new THREE.WebGLRenderer({canvas:$("canvas"),antialias:true}); }
catch { status.textContent="The character preview requires WebGL 2."; }
scene.add(new THREE.HemisphereLight(0xfff6ec,0xadbcc9,2.2));
const key=new THREE.DirectionalLight(0xffdfae,2.7); key.position.set(3,6,5);scene.add(key);
const rim=new THREE.DirectionalLight(0x95deff,1.4);rim.position.set(-4,4,-3);scene.add(rim);
const grid=new THREE.GridHelper(42,42,0x587677,0x2f454b);scene.add(grid);
const actor=new THREE.Group(), pivot=new THREE.Group();actor.add(pivot);scene.add(actor);
const ring=new THREE.Mesh(new THREE.RingGeometry(.87,1,64),new THREE.MeshBasicMaterial({color:0xffbb60,transparent:true,side:THREE.DoubleSide,depthWrite:false}));
ring.rotation.x=-Math.PI/2; scene.add(ring); ring.visible=false;
const trailPoints=[];
const trailGeo=new THREE.BufferGeometry();
const vertices=new Float32Array(10*6);
trailGeo.setAttribute("position",new THREE.BufferAttribute(vertices,3));
const indices=[];
for(let i=0;i<9;i++){const a=i*2;indices.push(a,a+1,a+2,a+2,a+1,a+3);}
trailGeo.setIndex(indices);
const trail=new THREE.Mesh(trailGeo,new THREE.MeshBasicMaterial({color:0xffda86,transparent:true,opacity:.56,side:THREE.DoubleSide,depthWrite:false}));
trail.frustumCulled=false;trail.visible=false;scene.add(trail);

let rig,chosen="",generation=0,active=true;
let axes=[0,0,0,0],flags=0,triggerHeld=false,manualRun=false;
const pads=[0,0,0,0],keys=new Set();
let orbit=.66,pitch=.21,yaw=0,phase=0,stride=0,jump=.78,dodge=.36;
const dodgeDir=v(), motion=v(), cameraTarget=v();
let action="",time=0,duration=1,queued=false,impactAge=1,contact=false;
const durations={fight:.74,combo:.66,aerial:.74,spin:.98,slam:1.08};
function start(kind){
    if(!rig || !active)return;
    if(kind==="jump"){
        if(jump>=.78 && dodge>=.36 && action!=="spin" && action!=="slam") jump=0;
        return;
    }
    if(kind==="dodge"){
        if(jump<.78 || dodge<.36 || action)return;
        moveDirection(dodgeDir);
        if(!dodgeDir.lengthSq()) dodgeDir.set(-Math.sin(yaw),0,-Math.cos(yaw));
        dodge=0;return;
    }
    if(dodge<.36)return;
    if(action){
        if(kind==="fight" && ["fight","combo","aerial"].includes(action) && time>.22*duration) queued=true;
        return;
    }
    if(kind==="spin" && jump<.78)return;
    action=kind==="fight" && jump<.78?"aerial":kind;
    duration=durations[action];time=0;queued=false;contact=false;
    if(kind==="slam") duration=Math.max(duration,(.78-jump)/.47);
}

function input(lx,ly,rx,ry,mask,rt){
    axes=[lx,ly,rx,ry].map(n=>clamp(n/32767,-1,1));
    for(const [bit,kind] of [[4096,"jump"],[8192,"dodge"],[16384,"fight"],[32768,"slam"]])
        if((mask&bit) && !(flags&bit))start(kind);
    if(rt>=140 && !triggerHeld){start("spin");triggerHeld=true;}
    if(rt<100)triggerHeld=false;
    flags=mask;
}

function select(){
    chosen=menu.value;generation++;status.textContent=chosen?"Loading character…":"Add a GLB to the Characters folder.";
    if(chosen)send("load",{name:chosen});
}
function catalog(names){
    const sorted=[...names].sort((a,b)=>Number(nameOf(b)==="Sun Wukong")-Number(nameOf(a)==="Sun Wukong") || a.localeCompare(b));
    if (sorted.length && sorted.length===menu.options.length && sorted.every((file,i)=>menu.options[i].value===file)) return;
    menu.replaceChildren(...sorted.map(file=>{
        const name=nameOf(file); return new Option(chinese[name]?name+" ("+chinese[name]+")":name,file);
    }));
    if(sorted.includes(chosen)){menu.value=chosen;return;}
    select();
}

function dispose(root){
    const meshes=new Set(),materials=new Set(),textures=new Set(),skeletons=new Set();
    root.traverse(n=>{
        if(n.geometry) meshes.add(n.geometry);
        if(n.skeleton)skeletons.add(n.skeleton);
        for(const m of [].concat(n.material||[])){materials.add(m);for(const value of Object.values(m))if(value?.isTexture)textures.add(value);}
    });
    for(const set of [meshes,materials,textures,skeletons]) for(const item of set)item.dispose();
}

async function loaded(name,bytes){
    if(name!==chosen || !renderer)return;
    const request=generation;
    let parsed;
    try{
        if(!bytes)throw new Error("File could not be read.");
        const data=Uint8Array.from(atob(bytes),c=>c.charCodeAt(0));
        parsed=(await new GLTFLoader().parseAsync(data.buffer,"")).scene;
        if(request!==generation){dispose(parsed);return;}
        const replacement=new CharacterRig(parsed,nameOf(name));
        if(rig){pivot.remove(rig.root);dispose(rig.root);}
        rig=replacement;
        const scale=1.45/rig.hipHeight;
        parsed.scale.multiplyScalar(scale);
        parsed.position.y-=1.45;
        pivot.add(parsed);
        action="";time=0;jump=.78;dodge=.36;queued=false;impactAge=1;stride=0;
        status.textContent="";
        if(!active)draw(0);
    }catch(error){
        if(parsed && rig?.root!==parsed)dispose(parsed);
        if(request===generation)status.textContent="Cannot display "+nameOf(name)+". "+error.message;
    }
}

function moveDirection(out){
    const x=clamp(axes[0]+pads[0]+Number(keys.has("KeyD"))-Number(keys.has("KeyA")),-1,1);
    const y=clamp(axes[1]+pads[1]+Number(keys.has("KeyW"))-Number(keys.has("KeyS")),-1,1);
    const mag=Math.hypot(x,y);
    out.set(Math.cos(orbit)*x-Math.sin(orbit)*y,0,-Math.sin(orbit)*x-Math.cos(orbit)*y);
    if(mag<=.12){out.set(0,0,0);return 0;}
    out.normalize();return clamp((mag-.12)/.88,0,1);
}
function updateTrail(t){
    if(action!=="spin" || t<.2 || t>.89){trailPoints.length=0;trail.visible=false;return;}
    const tip=rig.tip();
    trailPoints.push(tip);if(trailPoints.length>10)trailPoints.shift();
    trailPoints.forEach((point,i)=>{
        point.toArray(vertices,i*6);
        point.clone().lerp(actor.position,.09).toArray(vertices,i*6+3);
    });
    trailGeo.attributes.position.needsUpdate=true;
    trailGeo.setDrawRange(0,Math.max(0,trailPoints.length-1)*6);
    trail.visible=trailPoints.length>1;
}

let last=0;
function draw(dt){
    const w=stage.clientWidth,h=stage.clientHeight;
    if(!w || !h || !renderer)return;
    if($("canvas").width!==Math.floor(w*renderer.getPixelRatio()) || $("canvas").height!==Math.floor(h*renderer.getPixelRatio())){
        renderer.setSize(w,h,false);camera.aspect=w/h;camera.updateProjectionMatrix();
    }
    const lookX=axes[2]+pads[2],lookY=axes[3]+pads[3];
    if(Math.abs(lookX)>.12)orbit+=lookX*2.27*dt;
    if(Math.abs(lookY)>.12)pitch=clamp(pitch+lookY*1.31*dt,-.035,.96);
    const run=manualRun || !!(flags&512) || keys.has("ShiftLeft") || keys.has("ShiftRight");
    time+=dt;jump=Math.min(.78,jump+dt);
    let speed=moveDirection(motion);
    if(action==="spin" || action==="slam")speed=0;
    if(dodge<.36){
        const before=dodge/.36;dodge=Math.min(.36,dodge+dt);
        actor.position.addScaledVector(dodgeDir,1.65*((1-before)**2-(1-dodge/.36)**2));speed=0;
    }
    if(speed){
        if(action)speed*=1-.8*Math.sin(Math.PI*clamp(time/duration,0,1));
        actor.position.addScaledVector(motion,dt*speed*(run?5.7:2.7));
        const desired=Math.atan2(motion.x,motion.z);
        yaw+=Math.atan2(Math.sin(desired-yaw),Math.cos(desired-yaw))*Math.min(1,dt*14);
    }
    actor.position.clamp(v(-14,0,-14),v(14,0,14));
    stride+=clamp(speed-stride,-dt*9,dt*9);phase+=dt*(run?12:8)*stride;
    const t=clamp(time/duration,0,1), air=jump/.78, lift=4*air*(1-air);
    actor.rotation.y=yaw+(action==="spin"?2*Math.PI*ease(.16,.84,t):0);
    pivot.position.y=1.45+lift*1.55+.07*Math.abs(Math.cos(phase))*stride;
    pivot.rotation.x=air===1?0:2*Math.PI*ease(.06,.92,air);
    if(rig){
        rig.pose({phase,stride,run,tuck:lift,dodge:Math.sin(Math.PI*dodge/.36),kind:action,t});
        updateTrail(t);
        if(action==="slam" && t>=.47 && !contact){
            contact=true;impactAge=0;ring.position.copy(rig.tip());ring.position.y=.025;
        }
    }
    impactAge+=dt;
    ring.visible=impactAge<.55;
    if(ring.visible){const u=impactAge/.55;ring.scale.setScalar(.12+2.5*u*(2-u));ring.material.opacity=1-u*u;}
    if(action && t>=1){
        const previous=action;action="";
        if(queued)start(previous==="fight"?"combo":"fight");
    }
    const target=actor.position.clone();target.y=1.6+.45*lift;
    cameraTarget.lerp(target,last?1-Math.exp(-dt*9):1);
    const radius=(6.9+(action ? .75 : 0))*Math.max(1,1.1/camera.aspect);
    camera.position.copy(cameraTarget).add(v(Math.sin(orbit)*Math.cos(pitch),Math.sin(pitch),Math.cos(orbit)*Math.cos(pitch)).multiplyScalar(radius));
    camera.lookAt(cameraTarget);renderer.render(scene,camera);
}

const keyActions={KeyJ:"jump",KeyK:"fight",KeyI:"slam",KeyL:"dodge",KeyU:"spin"};
function fullscreen(){
    const el=$("#preview");
    if(document.fullscreenElement || document.webkitFullscreenElement)(document.exitFullscreen || document.webkitExitFullscreen).call(document);
    else (el.requestFullscreen || el.webkitRequestFullscreen).call(el);
}
for(const event of ["fullscreenchange","webkitfullscreenchange"])document.addEventListener(event,()=>{
    $("#fullscreen").textContent=document.fullscreenElement || document.webkitFullscreenElement?"Exit fullscreen":"Fullscreen";
});
window.addEventListener("keydown",e=>{
    if(!active || e.target===menu || e.metaKey || e.ctrlKey || e.altKey)return;
    keys.add(e.code);
    if(keyActions[e.code] || e.code==="F11"){
        e.preventDefault();
        if(!e.repeat){if(e.code==="F11")fullscreen();else start(keyActions[e.code]);}
    }
});
window.addEventListener("keyup",e=>keys.delete(e.code));
window.addEventListener("blur",()=>{keys.clear();pads.fill(0);});
function stick(el,index){
    const knob=el.querySelector("i");
    const update=e=>{
        const r=el.getBoundingClientRect(),x=(e.clientX-r.left-r.width/2)/18,y=(r.top+r.height/2-e.clientY)/18;
        const mag=Math.max(1,Math.hypot(x,y));pads[index]=x/mag;pads[index+1]=y/mag;
        knob.style.transform="translate("+12*x/mag+"px,"+(-12*y/mag)+"px)";
    };
    el.onpointerdown=e=>{el.setPointerCapture(e.pointerId);stage.focus();update(e);};
    el.onpointermove=e=>{if(el.hasPointerCapture(e.pointerId))update(e);};
    el.onlostpointercapture=()=>{pads[index]=pads[index+1]=0;knob.style.transform="";};
}
stick($("#move"),0);stick($("#look"),2);
$("#fullscreen").onclick=fullscreen;
$("#reset").onclick=()=>{orbit=.66;pitch=.21;};
$("#run").onclick=()=>{manualRun=!manualRun;$("#run").setAttribute("aria-pressed",manualRun);};
for(const button of document.querySelectorAll("[data-action]"))button.onclick=()=>start(button.dataset.action);
menu.onpointerdown=()=>send("list");menu.onfocus=()=>send("list");menu.onchange=select;
function visible(value){active=value;last=0;if(!active){keys.clear();pads.fill(0);}}
window.preview={input,catalog,loaded,visible};
if(renderer){
    renderer.setPixelRatio(Math.min(window.devicePixelRatio,2));
    renderer.setAnimationLoop(now=>{if(active){draw(last?Math.min(.08,(now-last)/1000):0);last=now;}});
    send("ready");
}
