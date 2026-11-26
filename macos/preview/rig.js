import {Bone, Box3, CylinderGeometry, Euler, MathUtils, Matrix4, Mesh, MeshStandardMaterial, Quaternion, Vector3} from "three";

const V = (x=0,y=0,z=0) => new Vector3(x,y,z);
const Q = () => new Quaternion();
export const ease = (a,b,t) => MathUtils.smoothstep(t,a,b);
const pulse = (a,b,c,t) => ease(a,b,t)-ease(b,c,t);
const position = node => node.getWorldPosition(V());

function role(name) {
    const clean = name.split(":").pop().replace(/^(mixamorig\d*|bip\d+)[_. -]*/i,"");
    const match = clean.match(/^(left|right)[_. -]*(.+)$/i);
    const suffix = clean.match(/^(.+?)[_. -](left|right|l|r)$/i);
    const stem = (match ? match[2] : suffix ? suffix[1] : clean).toLowerCase();
    const side = match ? match[1] : suffix ? suffix[2] : "";
    const aliases = {pelvis:"hips",upperleg:"thigh",upleg:"thigh",leg:"shin",lowerleg:"shin",calf:"shin",ankle:"foot",shoulder:"clavicle",arm:"upperarm",lowerarm:"forearm",wrist:"hand",spine1:"chest",upperchest:"chest"};
    return (aliases[stem] || stem) + (side ? "."+side[0].toLowerCase() : "");
}

// Determine which end of the longest rigid part is the tip, even when the shaft is tilted in bind pose.
function equipment(root, hands, upperTip) {
    const parts = new Map();
    root.traverse(mesh => {
        if (!mesh.isSkinnedMesh) return;
        const {skinIndex,skinWeight,position:vertices} = mesh.geometry.attributes;
        const index=skinIndex.getX(0);
        for (let i=0;i<vertices.count;i++) if (skinIndex.getX(i)!==index || skinWeight.getX(i)<0.999) return;
        let joint=mesh.skeleton.bones[index];
        while (joint && !hands.includes(joint.parent)) joint=joint.parent;
        if (!joint) return;
        const points=[];
        for (let i=0;i<vertices.count;i++) points.push(joint.worldToLocal(mesh.localToWorld(V().fromBufferAttribute(vertices,i))));
        const span=new Box3().setFromPoints(points).getSize(V()).length();
        if (!parts.has(joint)) parts.set(joint,[]);
        parts.get(joint).push({points,span});
    });
    let shaft, joint;
    for (const [bone,meshes] of parts) for (const part of meshes) {
        if (!shaft || part.span>shaft.span) { shaft=part; joint=bone; }
    }
    if (!joint) {
        joint=new Bone();
        hands[0].add(joint);
        const length=Math.max(0.4,position(hands[0]).y*1.7);
        const staff=new Mesh(new CylinderGeometry(length*.014,length*.014,length,12),new MeshStandardMaterial({color:0xd6ae5c}));
        staff.position.y=length*.1; joint.add(staff);
        return {joint,axis:V(0,1,0),length:length*.6};
    }
    const center=shaft.points.reduce((sum,p)=>sum.add(p),V()).divideScalar(shaft.points.length);
    const deltas=shaft.points.map(p=>p.clone().sub(center));
    let axis=V(.21,1,.31).normalize();
    for (let i=0;i<12;i++) {
        const next=V();
        for (const p of deltas) next.addScaledVector(p,p.dot(axis));
        if (next.lengthSq()>1e-12) axis=next.normalize();
    }
    let low=0,high=0;
    for (const part of parts.get(joint)) for (const p of part.points) {
        const along=p.dot(axis);
        low=Math.min(low,along); high=Math.max(high,along);
    }
    if (upperTip ? axis.y<0 : -low>high) { axis.negate(); high=-low; }
    return {joint,axis,length:Math.max(.05,high)};
}

function aim(bone,from,to,weight) {
    if (!weight || from.lengthSq()<1e-10 || to.lengthSq()<1e-10) return;
    const parent=bone.parent.getWorldQuaternion(Q());
    const delta=Q().setFromUnitVectors(from.normalize(),to.normalize());
    const local=parent.clone().invert().multiply(delta).multiply(parent).multiply(bone.quaternion);
    bone.quaternion.slerp(local,weight);
}

function reach(arm, target, weight) {
    const [shoulder,elbow,hand]=arm;
    if (!shoulder || !elbow || !hand) return;
    const a=position(shoulder), b=position(elbow), c=position(hand);
    const line=c.clone().lerp(target,weight).sub(a);
    const upper=a.distanceTo(b), lower=b.distanceTo(c);
    const distance=MathUtils.clamp(line.length(),Math.abs(upper-lower)+.0001,upper+lower-.0001);
    line.normalize();
    const end=a.clone().addScaledVector(line,distance);
    const along=(upper*upper-lower*lower+distance*distance)/(2*distance);
    const pole=b.clone().sub(a);
    pole.addScaledVector(line,-pole.dot(line));
    if (pole.lengthSq()<1e-8) pole.crossVectors(line,V(0,1,0));
    const bend=a.clone().addScaledVector(line,along).addScaledVector(pole.normalize(),Math.sqrt(Math.max(0,upper*upper-along*along)));
    aim(shoulder,b.sub(a),bend.clone().sub(a),1);
    aim(elbow,position(hand).sub(bend),end.sub(bend),1);
}

export class CharacterRig {
    constructor(scene,name) {
        this.root=scene;
        this.bones=new Map();
        scene.updateMatrixWorld(true);
        scene.traverse(node=>{
            if (node.isBone) this.bones.set(role(node.userData.name || node.name),node);
            if (node.isSkinnedMesh) node.frustumCulled=false;
        });
        const bone=k=>this.bones.get(k);
        for (const k of ["hips","hand.r","hand.l","thigh.l","thigh.r","shin.l","shin.r"]) {
            if (!bone(k)) throw new Error("Missing humanoid joint: "+k);
        }
        this.hipHeight=Math.max(.2,position(bone("hips")).y);
        this.push=/Bull Demon King|Sha Seng|Tang Seng/i.test(name);
        this.weapon=equipment(scene,[bone("hand.r"),bone("hand.l")],this.push);
        this.side=this.weapon.joint.parent===bone("hand.l")?"l":"r";
        this.fan=/fan/i.test(this.weapon.joint.name);
        this.rest=new Map([...this.bones].map(([key,b])=>[key,b.quaternion.clone()]));
        this.weaponRest=this.weapon.joint.quaternion.clone();
        const align=Q().setFromUnitVectors(V(0,1,0),this.weapon.axis);
        this.align=new Matrix4().makeRotationFromQuaternion(align);
        this.unalign=this.align.clone().invert();
        this.weapon.joint.matrixAutoUpdate=false;
        this.hipRest=bone("hips").position.clone();
    }

    pose({phase,stride,run,tuck,dodge,kind,t}) {
        const fight=kind==="fight" || kind==="combo" || kind==="aerial";
        const load=fight?pulse(0,.28,.55,t):0, sweep=fight?pulse(.29,.62,1,t):0;
        const sign=kind==="combo"?-1:1, mirror=this.side==="l"?-1:1;
        const slam=kind==="slam", spin=kind==="spin";
        const draw=slam?ease(0,.26,t)-ease(.33,.47,t):0;
        const plant=slam?ease(.33,.47,t)-ease(.75,1,t):0;
        const whirl=spin?ease(0,.22,t)-ease(.8,1,t):0;
        const stance=fight?ease(0,.22,t)-ease(.66,1,t):0;
        const crouch=12*stance+28*dodge+11*plant+20*whirl;
        const twist=mirror*sign*(-22*load+32*sweep)*(this.push ? .2 : 1);
        const swing=Math.sin(phase);
        for (const [key,bone] of this.bones) {
            const [part,side]=key.split("."), grip=side===this.side;
            const leg=(side==="l"?1:-1)*swing;
            let x=0,y=0,z=0;
            switch (part) {
            case "hips": y=-6*swing*stride; break;
            case "thigh": x=-leg*(run?46:30)*stride-(grip?24:40)*tuck-crouch; break;
            case "shin": x=(8+Math.max(0,-leg)*49)*stride+53*tuck+2*crouch; break;
            case "foot": x=leg*14*stride-18*tuck-crouch; break;
            case "spine": y=.55*twist; z=mirror*sign*(5*load-6*sweep); break;
            case "chest": y=8*swing*stride+twist-12*draw-16*whirl; x=(run?8:0)*stride-7*load+9*sweep+16*dodge+17*plant-7*draw+11*whirl;break;
            case "head": y=-.65*twist; x=3*load-5*sweep;break;
            case "upperarm":
                x=leg*24*stride-22*tuck-(grip?(this.push?110:32)*load+(kind==="aerial"?82:58)*sweep:23*load+11*sweep);
                x-=grip?152*draw+46*plant+54*whirl:108*draw+54*plant+27*whirl;
                z=mirror*(grip?-30*load-15*sweep-47*whirl:12*load+16*sweep+18*whirl);
                y=mirror*sign*(grip?-18*load+30*sweep:-8*sweep); break;
            case "forearm": x=-(10+12*(1-leg))*stride-18*tuck-(grip?43*load+12*sweep+14*draw:35*load+20*sweep+52*draw+20*plant+41*whirl); break;
            case "hand": if(grip){z=mirror*sign*(-35*load+52*sweep);x=-12*sweep+100*draw+11*plant;}break;
            case "scarf": case "cape": x=10*stride+8*tuck+18*plant;y=-sign*18*sweep+32*whirl;break;
            }
            bone.quaternion.copy(this.rest.get(key));
            if (x || y || z) bone.quaternion.multiply(Q().setFromEuler(new Euler(x*Math.PI/180,y*Math.PI/180,z*Math.PI/180)));
        }
        this.bones.get("hips").position.copy(this.hipRest).y-=this.hipHeight*(1-Math.cos(crouch*Math.PI/180));
        const {joint,axis,length}=this.weapon;
        joint.quaternion.copy(this.weaponRest); joint.scale.setScalar(1); joint.updateMatrix();
        const active=stance+whirl+draw+plant;
        if (!active) return;
        const arc=mirror*sign*(-64+110*ease(.24,.72,t))*Math.PI/180;
        let direction=V(Math.sin(arc),.08,Math.cos(arc));
        let scale=1+.82*sweep, width=1+.14*sweep;
        const rootQ=this.root.getWorldQuaternion(Q());
        if(this.push && fight){
            const pitch=(48-55*ease(.24,.6,t))*Math.PI/180;
            direction=V(-.18*mirror,Math.sin(pitch),Math.cos(pitch)).normalize();
            const other=this.side==="l"?"r":"l";
            const arm=s=>["upperarm","forearm","hand"].map(k=>this.bones.get(k+"."+s));
            const rear=arm(this.side),front=arm(other);
            if(rear[0] && front[0]){
                const scaleWorld=this.root.getWorldScale(V()).y;
                const center=position(rear[0]).lerp(position(front[0]),.46);
                const drive=ease(.25,.61,t);
                reach(rear,center.add(V(0,-.24+.13*drive,.12+.28*drive).multiplyScalar(scaleWorld).applyQuaternion(rootQ)),stance);
                reach(front,position(joint).addScaledVector(direction.clone().applyQuaternion(rootQ),.21*scaleWorld),stance);
            }
            scale=1+stance*(Math.max(1,3.95/length)-1);
        } else if(spin){direction=V(-.86*mirror,.03,.52);scale=1+.38*whirl;}
        else if(slam){direction=V(.18*mirror,.13*draw-1.1*plant,.97);scale=1+1.4*plant;}
        let worldDirection=direction.applyQuaternion(rootQ);
        if(slam && plant>0){
            const target=this.root.localToWorld(V(.58*mirror,0,2.55));
            target.y=.025;
            const toGround=target.sub(position(joint));
            const worldLength=length*this.root.getWorldScale(V()).y;
            scale=MathUtils.lerp(1.45,toGround.length()/worldLength,plant);
            width=1+1.9*plant;
            worldDirection.lerp(toGround.normalize(),plant);
        }
        if(this.fan && !slam) width=scale=1+1.65*active;
        // Turn the gripping wrist so the weapon and hand stay together.
        const worldAxis=axis.clone().applyQuaternion(joint.getWorldQuaternion(Q()));
        aim(joint.parent,worldAxis,worldDirection,Math.min(1,active));
        if(slam && plant>0){
            // Rotating the wrist also moves an offset grip. Use the final grip and
            // shaft direction to place the cap exactly on the floor at contact.
            const ray=axis.clone().applyQuaternion(joint.getWorldQuaternion(Q()));
            if(ray.y<-.05){
                const reach=(position(joint).y-.025)/(-ray.y*length*this.root.getWorldScale(V()).y);
                scale=MathUtils.lerp(scale,Math.max(.05,reach),plant);
            }
        }
        joint.matrix.multiply(this.align)
            .multiply(new Matrix4().makeScale(width,scale,width))
            .multiply(this.unalign);
        joint.matrixWorldNeedsUpdate=true;
    }

    tip() { return this.weapon.joint.localToWorld(this.weapon.axis.clone().multiplyScalar(this.weapon.length)); }
}
