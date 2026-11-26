using System;
using System.Collections.Generic;
using System.Windows.Media;
using System.Windows.Media.Media3D;

// The bundled asset has translation-only bind joints and packed float vertices.
public sealed class WukongRig
{
    sealed class Bone {
        public string Name;
        public int Parent;
        public Point3D Pivot;
        public Matrix3D Pose;
        public MatrixTransform3D Transform = new MatrixTransform3D();
    }
    sealed class Blend {
        public MeshGeometry3D Mesh;
        public Point3D[] Points;
        public Vector3D[] Normals;
        public byte[] Joints;
        public float[] Weights;
    }
    readonly List<Bone> bones = new List<Bone>();
    readonly List<Blend> blends = new List<Blend>();
    Point3D Grip, Cap;
    sealed class Attachment {
        public int Joint, Hand;
        public List<Point3D[]> Parts = new List<Point3D[]>();
    }
    readonly Dictionary<int,Attachment> attachments = new Dictionary<int,Attachment>();
    int weaponJoint = -1;
    bool leftHanded;
    bool fanAttack;
    bool overheadAttack;
    Quaternion weaponAlignment;
    public Vector3D SpinDirection { get { return new Vector3D(leftHanded ? 0.86 : -0.86,0.03,0.52); } }
    public Point3D StaffTip { get; private set; }
    public readonly Model3DGroup Model = new Model3DGroup();

    public void AddBone(string name, int parent, double x, double y, double z) {
        Point3D pivot = parent < 0 ? new Point3D() : bones[parent].Pivot;
        pivot += new Vector3D(x,y,z);
        bones.Add(new Bone {Name=name, Parent=parent, Pivot=pivot});
    }

    double bindScale = 1;

    // Use the head joint above the bind floor, independent of headwear or weapons.
    public void NormalizeBindHeight() {
        Bone head = bones.Find(b => b.Name == "Head");
        Bone hips = bones.Find(b => b.Name == "Hips");
        if (head != null && head.Pivot.Y > 0.0001) bindScale = 2.56 / head.Pivot.Y;
        else if (hips != null && hips.Pivot.Y > 0.0001) bindScale = 1.42 / hips.Pivot.Y;
        foreach (Bone bone in bones) {
            Point3D p = bone.Pivot;
            bone.Pivot = new Point3D(p.X * bindScale, p.Y * bindScale, p.Z * bindScale);
        }
    }

    public void AddMesh(byte[] data, int positions, int normals, int vertices, int indices,
        int indexCount, int joints, int weights, int[] jointMap, float red, float green, float blue) {
        var mesh = new MeshGeometry3D();
        var blend = new Blend {Mesh=mesh, Points=new Point3D[vertices], Normals=new Vector3D[vertices],
            Joints=new byte[vertices*4], Weights=new float[vertices*4]};
        Buffer.BlockCopy(data,joints,blend.Joints,0,vertices*4);
        Buffer.BlockCopy(data,weights,blend.Weights,0,vertices*16);
        for (int k=0; k<blend.Joints.Length; k++) {
            if (blend.Weights[k]==0) { blend.Joints[k]=0; continue; }
            int source=blend.Joints[k];
            if (source>=jointMap.Length || jointMap[source]>255)
                throw new FormatException("Vertex joint index exceeds the supported skin palette.");
            blend.Joints[k]=(byte)jointMap[source];
        }
        int rigidJoint = blend.Joints[0];
        bool rigid = true;
        for (int i=0; i<vertices; i++) {
            int p=positions+12*i, n=normals+12*i;
            mesh.Positions.Add(blend.Points[i]=new Point3D(bindScale * BitConverter.ToSingle(data,p),
                bindScale * BitConverter.ToSingle(data,p+4), bindScale * BitConverter.ToSingle(data,p+8)));
            mesh.Normals.Add(blend.Normals[i]=new Vector3D(BitConverter.ToSingle(data,n),
                BitConverter.ToSingle(data,n+4),BitConverter.ToSingle(data,n+8)));
            rigid &= blend.Joints[4*i]==rigidJoint && blend.Weights[4*i]==1;
        }
        for (int i=0; i<indexCount; i++) {
            int index = BitConverter.ToUInt16(data,indices+2*i);
            if (index >= vertices) throw new FormatException("Triangle index exceeds vertex count.");
            mesh.TriangleIndices.Add(index);
        }
        if (rigid) {
            // Group rigid parts by their attachment branch, including nested decoration joints.
            int joint = rigidJoint;
            while (bones[joint].Parent >= 0) {
                int parent = bones[joint].Parent;
                if (bones[parent].Name == "Hand.R" || bones[parent].Name == "Hand.L") {
                    Attachment item;
                    if (!attachments.TryGetValue(joint,out item)) {
                        item = new Attachment {Joint=joint, Hand=parent};
                        attachments.Add(joint,item);
                    }
                    item.Parts.Add(blend.Points);
                    break;
                }
                joint=parent;
            }
        }
        var mat = new DiffuseMaterial(new SolidColorBrush(Color.FromScRgb(1,red,green,blue)));
        mat.Freeze();
        var part = new GeometryModel3D(mesh,mat) {BackMaterial=mat};
        if (rigid) {
            mesh.Freeze();
            part.Transform=bones[rigidJoint].Transform;
        } else blends.Add(blend);
        Model.Children.Add(part);
    }

    // Power iteration on the covariance of the longest part finds the handle axis
    // without assuming upright weapons, mesh order, or a particular joint name.
    static Vector3D PrincipalAxis(Point3D[] points) {
        Vector3D center=new Vector3D();
        Rect3D bounds=Rect3D.Empty;
        foreach (Point3D p in points) { center+=(Vector3D)p; bounds.Union(p); }
        center/=points.Length;
        Vector3D axis=bounds.SizeX>bounds.SizeY && bounds.SizeX>bounds.SizeZ ? X :
                      bounds.SizeY>=bounds.SizeZ ? Y : Z;
        for (int pass=0; pass<10; pass++) {
            Vector3D next=new Vector3D();
            foreach (Point3D p in points) {
                Vector3D delta=(Vector3D)p-center;
                next+=Vector3D.DotProduct(delta,axis)*delta;
            }
            if (next.LengthSquared<1e-14) return axis;
            next.Normalize(); axis=next;
        }
        return axis;
    }

    public void BindEquipment(bool useUpperTip) {
        double longest=0;
        Attachment selected=null;
        Point3D[] shaft=null;
        foreach (Attachment item in attachments.Values) {
            foreach (Point3D[] part in item.Parts) {
                Rect3D bounds=Rect3D.Empty;
                foreach (Point3D p in part) bounds.Union(p);
                double size=new Vector3D(bounds.SizeX,bounds.SizeY,bounds.SizeZ).Length;
                if (size>longest) { longest=size; selected=item; shaft=part; }
            }
        }
        int right=bones.FindIndex(b=>b.Name=="Hand.R");
        int hips=bones.FindIndex(b=>b.Name=="Hips");
        double height=Math.Max(0.2,Math.Abs(bones[hips].Pivot.Y));
        if (selected==null || longest<0.5*height) {
            // An unarmed humanoid can perform the same moves with a preview-only staff.
            Grip=bones[right].Pivot;
            weaponJoint=bones.Count;
            AddBone("Preview equipment",right,0,0,0);
            double length=height*1.9, radius=length*0.018;
            var mesh=new MeshGeometry3D();
            for (int i=0;i<12;i++) {
                double angle=2*Math.PI*i/12;
                Vector3D radial=new Vector3D(radius*Math.Cos(angle),0,radius*Math.Sin(angle));
                mesh.Positions.Add(Grip+radial-Y*(0.4*length));
                mesh.Positions.Add(Grip+radial+Y*(0.6*length));
                int n=2*i, next=(n+2)%24;
                foreach(int k in new[]{n,n+1,next,next,n+1,next+1}) mesh.TriangleIndices.Add(k);
            }
            mesh.Freeze();
            var material=new DiffuseMaterial(Brushes.Goldenrod);
            Model.Children.Add(new GeometryModel3D(mesh,material){BackMaterial=material,Transform=bones[weaponJoint].Transform});
            Cap=Grip+Y*(0.6*length);
            weaponAlignment=Quaternion.Identity;
        } else {
            weaponJoint=selected.Joint;
            fanAttack=string.Equals(bones[weaponJoint].Name,"Fan",StringComparison.OrdinalIgnoreCase);
            string equipment=bones[weaponJoint].Name;
            overheadAttack=string.Equals(equipment,"Axe",StringComparison.OrdinalIgnoreCase) ||
                           string.Equals(equipment,"Halberd",StringComparison.OrdinalIgnoreCase);
            leftHanded=bones[selected.Hand].Name=="Hand.L";
            Grip=bones[weaponJoint].Pivot;
            Vector3D axis=PrincipalAxis(shaft);
            double near=0, far=0;
            foreach(Point3D[] part in selected.Parts)
                foreach(Point3D p in part) {
                    double along=Vector3D.DotProduct(p-Grip,axis);
                    near=Math.Min(near,along); far=Math.Max(far,along);
                }
            // The polearm head is at the upper end in bind pose, even with a long counterweight.
            if ((overheadAttack || useUpperTip) ? axis.Y<0 : -near>far) {axis=-axis; far=-near;}
            Cap=Grip+axis*far;
            Vector3D cross=Vector3D.CrossProduct(Y,axis);
            weaponAlignment=cross.LengthSquared<1e-12 ?
                (axis.Y<0 ? new Quaternion(X,180) : Quaternion.Identity) :
                new Quaternion(cross,Vector3D.AngleBetween(Y,axis));
        }
        attachments.Clear();
    }

    static readonly Vector3D X = new Vector3D(1,0,0), Y = new Vector3D(0,1,0), Z = new Vector3D(0,0,1);
    // Smooth independent timing envelopes let the torso lead the arm and the scarf settle last.
    static double Ease(double start, double end, double t) {
        double u = Math.Max(0, Math.Min(1, (t-start)/(end-start)));
        return u*u*(3-2*u);
    }
    static double Pulse(double start, double peak, double end, double t) {
        return Ease(start, peak, t) - Ease(peak, end, t);
    }

    // Aim the gripping hand and staff together. Only the magical staff changes size.
    void Aim(ref Matrix3D pose, Point3D grip, Vector3D direction, double weight) {
        if (weight <= 0) return;
        Vector3D current = pose.Transform(Cap-Grip);
        Vector3D axis = Vector3D.CrossProduct(current,direction);
        if (axis.LengthSquared < 1e-12) return;
        axis.Normalize();
        pose.RotateAt(new Quaternion(axis,weight*Vector3D.AngleBetween(current,direction)),grip);
    }

    sealed class Arm {
        public Bone Shoulder, Elbow, Wrist;
    }
    Arm rearArm, frontArm;

    Arm FindArm(string side) {
        return new Arm {
            Shoulder=bones.Find(b=>b.Name=="UpperArm."+side),
            Elbow=bones.Find(b=>b.Name=="Forearm."+side),
            Wrist=bones.Find(b=>b.Name=="Hand."+side)
        };
    }
    public void UseTwoHandedPush() {
        rearArm=FindArm(leftHanded ? "L" : "R");
        frontArm=FindArm(leftHanded ? "R" : "L");
        foreach (Arm arm in new[]{rearArm,frontArm})
            if (arm.Shoulder==null || arm.Elbow==null || arm.Wrist==null)
                throw new FormatException("The two-handed pose needs both arm chains.");
    }

    static void RotateToward(ref Matrix3D pose, Point3D pivot, Vector3D from, Vector3D to) {
        Vector3D axis=Vector3D.CrossProduct(from,to);
        if (axis.LengthSquared>1e-12)
            pose.RotateAt(new Quaternion(axis,Vector3D.AngleBetween(from,to)),pivot);
    }

    static void SetPose(Bone bone, Matrix3D pose) {
        bone.Pose=pose;
        bone.Transform.Matrix=pose;
    }

    // Solve the two segments without stretching the mesh. Keep the elbow outside the chest.
    static Vector3D PlaceHand(Arm arm, Point3D target, double weight) {
        Point3D shoulder=arm.Shoulder.Pose.Transform(arm.Shoulder.Pivot);
        Point3D elbow=arm.Elbow.Pose.Transform(arm.Elbow.Pivot);
        Point3D wrist=arm.Wrist.Pose.Transform(arm.Wrist.Pivot);
        Vector3D line=wrist+(target-wrist)*weight-shoulder;
        double upper=(elbow-shoulder).Length, lower=(wrist-elbow).Length;
        double distance=Math.Max(Math.Abs(upper-lower)+0.0001,Math.Min(upper+lower-0.0001,line.Length));
        line.Normalize();
        Point3D end=shoulder+line*distance;
        double along=(upper*upper-lower*lower+distance*distance)/(2*distance);
        Vector3D pole=elbow-shoulder;
        pole-=line*Vector3D.DotProduct(pole,line);
        if(pole.LengthSquared<1e-9) pole=Vector3D.CrossProduct(line,Y);
        if(pole.LengthSquared<1e-9) pole=X;
        pole.Normalize();
        Point3D bend=shoulder+line*along+pole*Math.Sqrt(Math.Max(0,upper*upper-along*along));
        Matrix3D upperPose=arm.Shoulder.Pose, lowerPose=arm.Elbow.Pose, handPose=arm.Wrist.Pose;
        RotateToward(ref upperPose,shoulder,elbow-shoulder,bend-shoulder);
        lowerPose.Translate(bend-elbow);
        RotateToward(ref lowerPose,bend,wrist-elbow,end-bend);
        handPose.Translate(end-wrist);
        SetPose(arm.Shoulder,upperPose); SetPose(arm.Elbow,lowerPose); SetPose(arm.Wrist,handPose);
        return end-wrist;
    }

    static double ArmReach(Arm arm) {
        return (arm.Elbow.Pivot-arm.Shoulder.Pivot).Length+
               (arm.Wrist.Pivot-arm.Elbow.Pivot).Length-0.001;
    }
    static Point3D WithinReach(Point3D point, Point3D center, double radius) {
        Vector3D delta=point-center;
        return delta.Length>radius ? center+delta*(radius/delta.Length) : point;
    }

    void PushWeapon(double attack) {
        double gripWeight=Ease(0,0.23,attack)-Ease(0.74,1,attack);
        if (gripWeight<=0) return;
        double drive=Ease(0.25,0.61,attack)-Ease(0.74,1,attack);
        Point3D a=rearArm.Shoulder.Pose.Transform(rearArm.Shoulder.Pivot);
        Point3D b=frontArm.Shoulder.Pose.Transform(frontArm.Shoulder.Pivot);
        Point3D center=a+0.46*(b-a);
        Point3D rear=center+new Vector3D(0,-0.24+0.13*drive,0.12+0.28*drive);
        Matrix3D weapon=bones[weaponJoint].Pose;
        Point3D grip=weapon.Transform(Grip);
        Vector3D direction=weapon.Transform(Cap)-grip;
        direction.Normalize();
        Vector3D palmOffset=grip-rearArm.Wrist.Pose.Transform(rearArm.Wrist.Pivot);
        Vector3D frontOffset=palmOffset+direction*0.21;
        // Find a shaft placement reachable by both wrists, even on broad-shouldered rigs.
        for (int i=0;i<16;i++) {
            rear=WithinReach(rear,b-frontOffset,ArmReach(frontArm));
            rear=WithinReach(rear,a,ArmReach(rearArm));
        }
        weapon.Translate(PlaceHand(rearArm,rear,gripWeight));
        PlaceHand(frontArm,weapon.Transform(Grip)+direction*0.21,gripWeight);
        SetPose(bones[weaponJoint],weapon);
        StaffTip=weapon.Transform(Cap);
    }

    public void Pose(double phase, double stride, double sprint, double tuck,
                     double attack, int variation, double dodge, double dodgeSide, double height) {
        bool spinning = variation == WukongScene.SpinVariation;
        double spinPose = spinning ? Ease(0,0.22,attack)-Ease(0.80,1,attack) : 0;
        bool slamming = variation == 3;
        double slamPhase = slamming ? attack : 1;
        double draw = Ease(0, 0.26, slamPhase) - Ease(0.33, 0.47, slamPhase);
        double plant = Ease(0.33, 0.47, slamPhase) - Ease(0.75, 1, slamPhase);
        double vault = Pulse(0.38, 0.62, 0.90, slamPhase);
        double enlarge = Ease(0.13, 0.30, slamPhase) - Ease(0.76, 0.96, slamPhase);
        double staffLength = 1;
        double staffWidth = 1;
        if (slamming || spinning) attack = 1;
        double swing = Math.Sin(phase);
        bool returning = variation == 1, aerial = variation == 2;
        double sign = returning ? -1 : 1;
        double load = Pulse(0, 0.28, 0.55, attack);
        double sweep = Pulse(0.29, 0.62, 1, attack);
        double wrist = Pulse(0.37, 0.70, 1, attack);
        double cloth = Pulse(0.43, 0.77, 1, attack);
        double settle = Pulse(0.54, 0.73, 1, attack);
        double stance = Ease(0, 0.22, attack) - Ease(0.66, 1, attack);
        double twist = sign * (-22*load + 32*sweep);
        if (overheadAttack) twist *= 0.2;
        double crouch = (aerial ? 0 : 12*stance) + 28*dodge + 11*plant + 20*spinPose;
        foreach (Bone bone in bones) {
            string role = bone.Name;
            if (leftHanded && (role.EndsWith(".R") || role.EndsWith(".L")))
                role = role.Substring(0,role.Length-1) + (role.EndsWith(".R") ? "L" : "R");
            bool left=role.EndsWith(".L");
            double leg=left ? swing : -swing;
            double x=0,y=0,z=0;
            switch (role.Split('.')[0]) {
                case "Thigh": x=-leg*(30+16*sprint)*stride-(left?40:24)*tuck-crouch; break;
                case "Shin": x=(8+Math.Max(0,-leg)*49)*stride+53*tuck+2*crouch; break;
                case "Foot": x=leg*14*stride-18*tuck-crouch; break;
                case "Hips": y=-6*swing*stride; break;
                case "Spine": y=0.55*twist; z=sign*(5*load-6*sweep)-13*dodgeSide*dodge; break;
                case "Chest": y=8*swing*stride+twist; x=8*sprint*stride-7*load+9*settle+16*dodge; break;
                case "Head": y=-0.65*twist; x=3*load-5*settle; break;
                case "Clavicle": y=(left ? -4 : 8)*sign*sweep; break;
                case "UpperArm":
                    x=leg*24*stride-22*tuck;
                    x-=left ? 23*load+11*sweep : (returning?45:32)*load+(aerial?82:58)*sweep;
                    z+=left ? 12*load+16*sweep : -30*load-15*sweep;
                    y+=left ? -8*sweep : sign*(-18*load+30*sweep);
                    break;
                case "Forearm":
                    x=-(10+12*(1-leg))*stride-18*tuck;
                    x-=left ? 35*load+20*sweep : 43*load+12*sweep;
                    break;
                // Rotate the gripping hand; its child staff inherits exactly the same transform.
                case "Hand": if (!left) { z=sign*(-35*load+52*wrist); x=-12*wrist; } break;
                case "Scarf": x=10*stride+8*tuck; y=-sign*18*cloth; break;
                case "ScarfTip": y=-sign*12*cloth; break;
            }
            switch (role) {
                case "Hips": x += 58*vault; z -= 13*vault; break;
                case "Thigh.L": x -= 48*vault; break;
                case "Thigh.R": x += 28*vault; break;
                case "Shin.R": x += 35*vault; break;
                case "Chest": x += 17*plant-7*draw; y -= 12*draw; break;
                case "Head": x += 5*draw-3*plant; break;
                case "UpperArm.R": x -= 152*draw+46*plant; z -= 16*draw; break;
                case "Forearm.R": x -= 14*draw; break;
                case "Hand.R": x += 100*draw+11*plant; z += 16*draw; break;
                case "UpperArm.L": x -= 108*draw+54*plant; break;
                case "Forearm.L": x -= 52*draw+20*plant; break;
                case "Scarf": x += 18*plant; break;
            }
            if (overheadAttack && !slamming) {
                if (role=="UpperArm.R") {
                    x-=88*load;
                    z+=18*load;
                    y*=0.2;
                } else if (role=="Forearm.R") {
                    x+=22*load+8*sweep;
                } else if (role=="Chest") {
                    x+=14*sweep-8*load;
                }
            }
            if (spinning) {
                if (role=="UpperArm.R") { x-=54*spinPose; z-=47*spinPose; }
                if (role=="UpperArm.L") { x-=27*spinPose; z+=18*spinPose; }
                if (role=="Forearm.L") x-=41*spinPose;
                if (role=="Chest") { y-=16*spinPose; x+=11*spinPose; }
                if (role=="Scarf" || role=="Cape") y+=32*spinPose;
            }
            if (leftHanded) { y=-y; z=-z; }
            Matrix3D m=Matrix3D.Identity;
            if (x!=0 || y!=0 || z!=0) {
                Quaternion q=new Quaternion(X,x)*new Quaternion(Y,y)*new Quaternion(Z,z);
                m.RotateAt(q,bone.Pivot);
            }
            if (bone.Name=="Hips")
                m.Translate(new Vector3D(0, -1.39*(1-Math.Cos(crouch*Math.PI/180)), 0));
            if (bone.Name=="Hips")
                m.Translate(new Vector3D(0,0.56*vault,0.62*vault));
            if (bone.Parent>=0) m.Append(bones[bone.Parent].Pose);
            if (role=="Hand.R") {
                Point3D grip = m.Transform(Grip);
                if (slamming) {
                    Aim(ref m,grip,new Vector3D(leftHanded ? -0.18 : 0.18,0.13,0.97),draw);
                    // Hold the cap at one floor point as the body swings past the grip.
                    Vector3D toGround = new Point3D(leftHanded ? -0.58 : 0.58,0.015-height,2.55) - grip;
                    Aim(ref m,grip,toGround,plant);
                    double extended = 1+0.45*enlarge;
                    staffLength = extended + (toGround.Length/(Cap-Grip).Length-extended)*plant;
                    staffWidth = 1+1.9*enlarge;
                } else if (spinning) {
                    Aim(ref m,grip,SpinDirection,spinPose);
                    staffLength=1+0.38*spinPose;
                    if (fanAttack) staffWidth=staffLength=1+1.1*spinPose;
                } else if (rearArm!=null) {
                    double drive=Ease(0.24,0.60,attack);
                    double pitch=(48-55*drive)*Math.PI/180;
                    double aim=Ease(0,0.22,attack)-Ease(0.74,1,attack);
                    Aim(ref m,grip,new Vector3D(leftHanded ? -0.18 : 0.18, Math.Sin(pitch),Math.Cos(pitch)),aim);
                    // Match the extended staff/rake reach regardless of where this GLB puts its grip.
                    double reach=Ease(0.19,0.60,attack)-Ease(0.74,1,attack);
                    staffLength=1+reach*(Math.Max(1,3.95/(Cap-Grip).Length)-1);
                } else if (overheadAttack) {
                    // Local +Z is the character's forward direction, independent of camera orbit.
                    double pitch=(64-91*Ease(0.29,0.65,attack))*Math.PI/180;
                    double aim=Ease(0,0.19,attack)-Ease(0.73,1,attack);
                    Aim(ref m,grip,new Vector3D(0,Math.Sin(pitch),Math.Cos(pitch)),aim);
                    staffLength=1+0.35*sweep;
                } else {
                    double arc = Ease(0.24,0.72,attack);
                    double bearing = (leftHanded ? -sign : sign)*(-64+110*arc)*Math.PI/180;
                    double reach = Ease(0.14,0.45,attack)-Ease(0.69,1,attack);
                    Aim(ref m,grip,new Vector3D(Math.Sin(bearing),0.08,Math.Cos(bearing)),reach);
                    staffLength = 1+0.82*reach;
                    staffWidth = 1+0.14*reach;
                    if (fanAttack) {
                        // Enlarge the whole leaf about the grip, including its ribs and trim.
                        double bloom = Ease(0.09,0.38,attack)-Ease(0.68,1,attack);
                        staffLength = staffWidth = 1+1.65*bloom;
                    }
                }
            }
            if (bone==bones[weaponJoint]) {
                // Orient the scale along the sloping shaft in bind space, about the palm.
                Matrix3D shape=Matrix3D.Identity;
                Quaternion inverse = weaponAlignment;
                inverse.Invert();
                shape.RotateAt(inverse,Grip);
                shape.ScaleAt(new Vector3D(staffWidth,staffLength,staffWidth),Grip);
                shape.RotateAt(weaponAlignment,Grip);
                shape.Append(m);
                m=shape;
                StaffTip=m.Transform(Cap);
            }
            bone.Pose=m;
            bone.Transform.Matrix=m;
        }
        if (rearArm!=null && !slamming && !spinning) PushWeapon(attack);
        foreach (Blend b in blends) {
            var points=new Point3DCollection(b.Points.Length);
            var normals=new Vector3DCollection(b.Points.Length);
            for (int i=0;i<b.Points.Length;i++) {
                Vector3D p=new Vector3D(), n=new Vector3D();
                for (int k=4*i;k<4*i+4;k++) {
                    double w=b.Weights[k];
                    if (w==0) continue;
                    Matrix3D m=bones[b.Joints[k]].Pose;
                    p+=(Vector3D)m.Transform(b.Points[i])*w;
                    n+=m.Transform(b.Normals[i])*w;
                }
                points.Add((Point3D)p); n.Normalize(); normals.Add(n);
            }
            points.Freeze(); normals.Freeze();
            b.Mesh.Positions=points; b.Mesh.Normals=normals;
        }
    }
}

public sealed class WukongScene
{
    WukongRig rig;
    readonly PerspectiveCamera camera;
    readonly TranslateTransform3D location;
    readonly AxisAngleRotation3D facing;
    readonly AxisAngleRotation3D flip;
    double phase, stride, orbit=38, pitch=12, jumpTime=1, attackTime=1, cameraX, cameraZ;
    const double DodgeDuration = 0.43;
    double dodgeTime = DodgeDuration, dodgeX, dodgeZ, dodgeSide;
    double attackDuration = 0.74;
    double actionFraming;
    public const int SpinVariation = 4;
    int variation;
    double spinHeading;
    readonly List<Point3D> trailTips = new List<Point3D>();
    readonly GeometryModel3D trailModel = new GeometryModel3D();
    public readonly Model3DGroup SpinTrail = new Model3DGroup();
    const double SlamContact = 0.47;
    bool impactPending;
    double impactAge = 1;
    readonly SolidColorBrush impactBrush = new SolidColorBrush(Colors.Gold);
    readonly ScaleTransform3D impactScale = new ScaleTransform3D();
    readonly TranslateTransform3D impactPosition = new TranslateTransform3D();
    public readonly Model3DGroup Impact = new Model3DGroup();
    readonly GeometryModel3D shockwave;
    bool queuedAttack, posed;
    public double MoveX, MoveY, LookX, LookY;
    public bool Running;
    public WukongScene(WukongRig rig, PerspectiveCamera camera, TranslateTransform3D location, AxisAngleRotation3D facing, AxisAngleRotation3D flip) {
        var trailMaterial=new EmissiveMaterial(new SolidColorBrush(Color.FromArgb(158,255,206,102)));
        trailMaterial.Freeze();
        trailModel.Material=trailModel.BackMaterial=trailMaterial;
        SpinTrail.Children.Add(trailModel);
        this.flip=flip;
        this.rig=rig; this.camera=camera; this.location=location; this.facing=facing;
        var mesh = new MeshGeometry3D();
        for (int i=0; i<64; i++) {
            double angle = 2*Math.PI*i/64;
            double x = Math.Cos(angle), z = Math.Sin(angle);
            mesh.Positions.Add(new Point3D(x,0,z));
            mesh.Positions.Add(new Point3D(0.91*x,0.035,0.91*z));
            int outer = i*2, next = (outer+2)%128;
            foreach (int index in new[]{outer,next,outer+1,next,next+1,outer+1})
                mesh.TriangleIndices.Add(index);
        }
        for (int i=0; i<14; i++) {
            double angle=i*2*Math.PI/14, x=Math.Cos(angle), z=Math.Sin(angle);
            int n=mesh.Positions.Count;
            mesh.Positions.Add(new Point3D(0.77*x-0.025*z,0,0.77*z+0.025*x));
            mesh.Positions.Add(new Point3D(0.77*x+0.025*z,0,0.77*z-0.025*x));
            mesh.Positions.Add(new Point3D(1.12*x,0.22+0.11*(i%3),1.12*z));
            mesh.TriangleIndices.Add(n); mesh.TriangleIndices.Add(n+1); mesh.TriangleIndices.Add(n+2);
        }
        mesh.Freeze();
        var material = new EmissiveMaterial(impactBrush);
        shockwave = new GeometryModel3D(mesh,material){BackMaterial=material};
        var transform = new Transform3DGroup();
        transform.Children.Add(impactScale);
        transform.Children.Add(impactPosition);
        Impact.Transform=transform;
    }
    public void SelectRig(WukongRig replacement) {
        rig = replacement;
        posed = false;
        Step(0);
    }
    public void Spin() {
        if (attackTime<attackDuration || jumpTime<0.78 || dodgeTime<DodgeDuration) return;
        spinHeading=facing.Angle;
        variation=SpinVariation;
        attackDuration=0.98;
        attackTime=0;
        queuedAttack=false;
    }

    void UpdateSpinTrail(double beat) {
        if (beat<0.20 || beat>0.89) {
            trailTips.Clear();
            trailModel.Geometry=null;
            return;
        }
        double yaw=facing.Angle*Math.PI/180;
        Point3D p=rig.StaffTip;
        trailTips.Add(new Point3D(location.OffsetX+p.X*Math.Cos(yaw)+p.Z*Math.Sin(yaw),
            location.OffsetY+p.Y,location.OffsetZ-p.X*Math.Sin(yaw)+p.Z*Math.Cos(yaw)));
        if (trailTips.Count>5) trailTips.RemoveAt(0);
        var mesh=new MeshGeometry3D();
        for (int i=0;i<trailTips.Count;i++) {
            Point3D outer=trailTips[i];
            double width=0.12*(i+1)/trailTips.Count;
            mesh.Positions.Add(outer);
            mesh.Positions.Add(new Point3D(outer.X+(location.OffsetX-outer.X)*width,
                outer.Y-width*0.6,outer.Z+(location.OffsetZ-outer.Z)*width));
            int n=i*2;
            if (i>0) foreach (int index in new[]{n-2,n-1,n,n,n-1,n+1}) mesh.TriangleIndices.Add(index);
        }
        mesh.Freeze();
        trailModel.Geometry=mesh;
    }

    public void Jump() { if(jumpTime>=0.78 && dodgeTime>=DodgeDuration && !((variation==3 || variation==SpinVariation) && attackTime<attackDuration)) jumpTime=0; }
    public void Attack() {
        if (dodgeTime < DodgeDuration) return;
        if (attackTime >= attackDuration) StartAttack(false);
        else if (variation != 3 && variation != SpinVariation && attackTime >= 0.22*attackDuration) queuedAttack = true;
    }
    public void Slam() {
        if (attackTime < attackDuration || dodgeTime < DodgeDuration) return;
        variation=3;
        // An airborne slam reaches contact only after landing.
        attackDuration=Math.Max(1.08, (0.78-jumpTime)/SlamContact);
        attackTime=0;
        impactPending=true;
        queuedAttack=false;
    }

    void UpdateImpact(double dt) {
        if (impactPending && attackTime >= attackDuration*SlamContact) {
            Point3D tip = rig.StaffTip;
            double yaw=facing.Angle*Math.PI/180;
            impactPosition.OffsetX=location.OffsetX+tip.X*Math.Cos(yaw)+tip.Z*Math.Sin(yaw);
            impactPosition.OffsetY=0.025;
            impactPosition.OffsetZ=location.OffsetZ-tip.X*Math.Sin(yaw)+tip.Z*Math.Cos(yaw);
            impactAge=0;
            impactPending=false;
            Impact.Children.Add(shockwave);
        } else impactAge+=dt;
        if (Impact.Children.Count==0) return;
        double t=Math.Min(1,impactAge/0.55);
        double radius=0.12+2.5*t*(2-t);
        impactScale.ScaleX=impactScale.ScaleZ=radius;
        impactScale.ScaleY=0.3+Math.Sin(Math.PI*t);
        impactBrush.Opacity=1-t*t;
        if (t>=1) Impact.Children.Clear();
    }
    void StartAttack(bool followUp) {
        variation = jumpTime < 0.78 ? 2 : (followUp && variation == 0 ? 1 : 0);
        attackDuration = variation == 1 ? 0.66 : 0.74;
        attackTime = 0;
        queuedAttack = false;
    }
    public void Dodge() {
        if (jumpTime < 0.78 || dodgeTime < DodgeDuration || attackTime < attackDuration) return;
        double angle = orbit*Math.PI/180;
        double length = Math.Sqrt(MoveX*MoveX + MoveY*MoveY);
        if (length > 0.12) {
            dodgeX = (Math.Cos(angle)*MoveX - Math.Sin(angle)*MoveY)/length;
            dodgeZ = (-Math.Sin(angle)*MoveX - Math.Cos(angle)*MoveY)/length;
        } else {
            double heading = facing.Angle*Math.PI/180;
            dodgeX = -Math.Sin(heading);
            dodgeZ = -Math.Cos(heading);
        }
        double yaw = facing.Angle*Math.PI/180;
        dodgeSide = dodgeX*Math.Cos(yaw) - dodgeZ*Math.Sin(yaw);
        dodgeTime = 0;
    }
    static double DodgeProgress(double time) {
        double u = Math.Min(1, time/DodgeDuration);
        return u*u*(3-2*u);
    }
    public void ResetCamera() { orbit=38; pitch=12; }
    static double Clamp(double v,double lo,double hi) {return Math.Max(lo,Math.Min(hi,v));}
    public void Step(double elapsed) {
        double dt=Clamp(elapsed,0,0.08);
        orbit+=Math.Abs(LookX)>0.12 ? LookX*130*dt : 0;
        pitch=Clamp(pitch+(Math.Abs(LookY)>0.12 ? LookY*75*dt : 0),-2,55);
        double angle=orbit*Math.PI/180, sin=Math.Sin(angle), cos=Math.Cos(angle);
        double magnitude=Math.Sqrt(MoveX*MoveX+MoveY*MoveY);
        double input=Clamp((magnitude-0.12)/0.88,0,1);
        bool spinActive=variation==SpinVariation && attackTime<attackDuration;
        if (spinActive || (variation==3 && attackTime<attackDuration)) input=0;
        bool dodging = dodgeTime < DodgeDuration;
        if (dodging) {
            double before = DodgeProgress(dodgeTime);
            dodgeTime += dt;
            double travel = 1.65*(DodgeProgress(dodgeTime)-before);
            location.OffsetX = Clamp(location.OffsetX + dodgeX*travel,-14,14);
            location.OffsetZ = Clamp(location.OffsetZ + dodgeZ*travel,-14,14);
            input = 0;
        } else if (attackTime < attackDuration && jumpTime >= 0.78) {
            double progress = attackTime/attackDuration;
            input *= 1 - 0.8*Math.Sin(Math.PI*progress);
        }
        double speed=(Running ? 5.7 : 2.7)*input;
        bool animate=stride>0 || input>0 || jumpTime<0.78 || attackTime<attackDuration || dodging || !posed;
        stride+=Clamp(input-stride,-dt*9,dt*9);
        if(input>0) {
            double dx=(cos*MoveX-sin*MoveY)/magnitude, dz=(-sin*MoveX-cos*MoveY)/magnitude;
            location.OffsetX=Clamp(location.OffsetX+dx*speed*dt,-14,14);
            location.OffsetZ=Clamp(location.OffsetZ+dz*speed*dt,-14,14);
            double desired=Math.Atan2(dx,dz)*180/Math.PI;
            facing.Angle+=Math.IEEERemainder(desired-facing.Angle,360)*Math.Min(1,dt*14);
        }
        phase+=dt*(Running ? 12 : 8)*stride;
        jumpTime+=dt; attackTime+=dt;
        if (queuedAttack && attackTime >= attackDuration) StartAttack(true);
        double t=Math.Min(1,jumpTime/0.78), airborne=4*t*(1-t);
        // Turn about the hips in character space. Leave time to extend the legs before landing.
        double turn=Clamp((t-0.06)/0.86,0,1);
        flip.Angle = turn>=1 ? 0 : 360*turn*turn*(3-2*turn);
        double tuck=airborne*(1+0.48*Math.Sin(Math.PI*turn));
        location.OffsetY=1.55*airborne+0.09*Math.Abs(Math.Cos(phase))*stride;
        if(animate) {
            rig.Pose(phase,stride,Running?1:0,tuck,Math.Min(1,attackTime/attackDuration),
                     variation, Math.Sin(Math.PI*Math.Min(1,dodgeTime/DodgeDuration)), dodgeSide, location.OffsetY);
            posed=true;
        }
        UpdateImpact(dt);
        double beat = Math.Min(1,attackTime/attackDuration);
        double frameTarget = Math.Min(1,Math.Min(beat/0.22,(1-beat)/0.18));
        actionFraming += (frameTarget-actionFraming)*Math.Min(1,dt*12);
        if (spinActive) {
            double u=Clamp((beat-0.16)/0.68,0,1);
            double rotation=360*u*u*(3-2*u);
            double windup=beat<0.23 ? 13*Math.Sin(Math.PI*beat/0.23) : 0;
            facing.Angle=beat>=1 ? spinHeading : spinHeading+rotation-windup;
            UpdateSpinTrail(beat);
        }
        double heading = (spinActive ? spinHeading : facing.Angle)*Math.PI/180;
        cameraX+=(location.OffsetX+Math.Sin(heading)*actionFraming*0.9-cameraX)*Math.Min(1,dt*5);
        cameraZ+=(location.OffsetZ+Math.Cos(heading)*actionFraming*0.9-cameraZ)*Math.Min(1,dt*5);
        double elevation=pitch*Math.PI/180;
        Point3D target=new Point3D(cameraX,1.95+0.5*airborne,cameraZ);
        Vector3D offset=new Vector3D(sin*Math.Cos(elevation),Math.Sin(elevation),cos*Math.Cos(elevation))*(8.8+2.2*actionFraming);
        camera.Position=target+offset; camera.LookDirection=-offset;
    }

    public static GeometryModel3D Floor() {
        var mesh=new MeshGeometry3D();
        for(int i=-20;i<=20;i++) {
            AddStrip(mesh,i,-20,i+0.025,20);
            AddStrip(mesh,-20,i,20,i+0.025);
        }
        var material=new DiffuseMaterial(new SolidColorBrush(Color.FromRgb(58,91,87)));
        var floor=new GeometryModel3D(mesh,material){BackMaterial=material};
        floor.Freeze();return floor;
    }
    static void AddStrip(MeshGeometry3D mesh,double x,double z,double endX,double endZ) {
        int n=mesh.Positions.Count;
        mesh.Positions.Add(new Point3D(x,-0.025,z));mesh.Positions.Add(new Point3D(x,-0.025,endZ));
        mesh.Positions.Add(new Point3D(endX,-0.025,endZ));mesh.Positions.Add(new Point3D(endX,-0.025,z));
        foreach(int i in new[]{0,1,2,0,2,3}) mesh.TriangleIndices.Add(n+i);
    }
}
