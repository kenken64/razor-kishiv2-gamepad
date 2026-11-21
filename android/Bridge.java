package net.kishi.bridge;

import android.app.Activity;
import android.os.Bundle;
import android.view.*;
import android.widget.*;
import android.hardware.input.InputManager;
import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.util.concurrent.*;

public class Bridge extends Activity implements InputManager.InputDeviceListener {
    EditText host, pin;
    Button connect;
    TextView status;
    Session session;
    int device = -1, buttons, hat, lt, rt;
    boolean lbTrigger, rbTrigger;
    short lx, ly, rx, ry;

    final int ink=0xff101517, card=0xff1a2225, soft=0xffa8bcba, white=0xfff3faf6, lime=0xffbcf777;
    TextView controllerName, linkState, latency;
    Scope scope;

    int dp(float value){return Math.round(value*getResources().getDisplayMetrics().density);}
    android.graphics.drawable.GradientDrawable surface(int color,int radius,int border){
        android.graphics.drawable.GradientDrawable bg=new android.graphics.drawable.GradientDrawable();
        bg.setColor(color); bg.setCornerRadius(dp(radius));
        if(border!=0) bg.setStroke(dp(1),border);
        return bg;
    }
    TextView label(String value,float size,int color,boolean bold){
        TextView t=new TextView(this); t.setText(value); t.setTextSize(size); t.setTextColor(color);
        if(bold) t.setTypeface(android.graphics.Typeface.create("sans-serif-medium",0));
        return t;
    }
    LinearLayout column(){
        LinearLayout col=new LinearLayout(this); col.setOrientation(1); return col;
    }
    void insert(LinearLayout parent,View child,int margin,int height){
        LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,height<0?height:dp(height));
        p.topMargin=dp(margin); parent.addView(child,p);
    }
    EditText field(LinearLayout parent,String name,String example,int type){
        TextView caption=label(name,14,white,true); insert(parent,caption,14,-2);
        EditText input=new EditText(this); input.setId(View.generateViewId()); caption.setLabelFor(input.getId());
        input.setSingleLine(); input.setInputType(type); input.setTextSize(17); input.setTextColor(white);
        input.setHint(example); input.setHintTextColor(soft); input.setPadding(dp(14),0,dp(12),0);
        android.graphics.drawable.StateListDrawable states=new android.graphics.drawable.StateListDrawable();
        states.addState(new int[]{android.R.attr.state_focused},surface(ink,12,lime));
        states.addState(new int[]{},surface(ink,12,0xff445654)); input.setBackground(states);
        insert(parent,input,5,50); return input;
    }
    static final String PROFILE_PREFIX = "receiver.profile.";

    void showProfiles() {
        java.util.TreeMap<String,String> profiles = new java.util.TreeMap<>();
        for (java.util.Map.Entry<String,?> item : getPreferences(0).getAll().entrySet()) {
            if (item.getKey().startsWith(PROFILE_PREFIX) && item.getValue() instanceof String) {
                profiles.put(item.getKey().substring(PROFILE_PREFIX.length()), (String)item.getValue());
            }
        }
        String[] names = profiles.keySet().toArray(new String[0]);
        String[] rows = new String[names.length];
        for (int i=0; i<names.length; i++) rows[i] = names[i] + "\n" + profiles.get(names[i]);
        android.app.AlertDialog.Builder dialog = new android.app.AlertDialog.Builder(this)
            .setTitle("Receiver profiles").setNegativeButton("Close", null)
            .setPositiveButton("Save current address", (d,w) -> saveProfile());
        if (rows.length == 0) dialog.setMessage("Save your PC address under a name to use it again.");
        else dialog.setItems(rows, (d,index) -> {
            if (session != null) {
                Toast.makeText(this,"Disconnect to switch receivers.",Toast.LENGTH_SHORT).show();
                return;
            }
            String address = profiles.get(names[index]);
            if (!address.equals(host.getText().toString().trim())) pin.setText("");
            host.setText(address);
            getPreferences(0).edit().putString("host",address).apply();
            status.setText("Selected " + names[index]);
            pin.requestFocus();
        });
        dialog.show();
    }

    void saveProfile() {
        String address = host.getText().toString().trim();
        if (address.isEmpty()) {
            host.setError("Enter the receiver address first");
            host.requestFocus();
            return;
        }
        EditText name = new EditText(this);
        name.setSingleLine(); name.setHint("Profile name");
        LinearLayout box = column(); box.setPadding(dp(24),dp(8),dp(24),0); box.addView(name);
        android.app.AlertDialog dialog = new android.app.AlertDialog.Builder(this)
            .setTitle("Save receiver profile").setMessage(address).setView(box)
            .setNegativeButton("Cancel",null).setPositiveButton("Save",null).create();
        dialog.show();
        dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String title = name.getText().toString().trim();
            if (title.isEmpty()) {name.setError("Enter a profile name"); return;}
            String key = PROFILE_PREFIX + title;
            Runnable save = () -> {
                getPreferences(0).edit().putString(key,address).putString("host",address).apply();
                Toast.makeText(this,"Saved " + title,Toast.LENGTH_SHORT).show();
                dialog.dismiss();
            };
            if (getPreferences(0).contains(key) && !address.equals(getPreferences(0).getString(key,""))) {
                new android.app.AlertDialog.Builder(this).setTitle("Update " + title + "?")
                    .setMessage("Change the saved address to " + address + "?")
                    .setNegativeButton("Cancel",null).setPositiveButton("Update",(d,w)->save.run()).show();
            } else save.run();
        });
    }
    void refreshDevice(){
        String name="Attach your controller";
        for(int id:InputDevice.getDeviceIds()){
            InputDevice d=InputDevice.getDevice(id);
            if(d!=null && !d.isVirtual() && (d.supportsSource(InputDevice.SOURCE_GAMEPAD)||d.supportsSource(InputDevice.SOURCE_JOYSTICK))){
                name=d.getName().replaceAll("(?i)\\bRazer(?:\\s+Razer)+\\b", "Razer"); if(device<0 || device==id) break;
            }
        }
        controllerName.setText(name);
    }
    public void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().setStatusBarColor(ink); getWindow().setNavigationBarColor(ink);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE | WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
        boolean wide=getResources().getConfiguration().screenWidthDp>=600;
        ScrollView scroll=new ScrollView(this); scroll.setFillViewport(true); scroll.setBackgroundColor(ink);
        scroll.setOnApplyWindowInsetsListener((v,i)->{v.setPadding(i.getSystemWindowInsetLeft(),i.getSystemWindowInsetTop(),i.getSystemWindowInsetRight(),i.getSystemWindowInsetBottom());return i;});
        LinearLayout root=column(); root.setPadding(dp(20),dp(14),dp(20),dp(20)); root.setFocusableInTouchMode(true); scroll.addView(root);
        LinearLayout header=new LinearLayout(this); header.setGravity(Gravity.CENTER_VERTICAL); root.addView(header);
        TextView title=label("Kishi Wi-Fi",32,white,true); title.setLetterSpacing(-0.045f);
        header.addView(title,new LinearLayout.LayoutParams(0,-2,1));
        linkState=label("Offline",13,white,true); linkState.setBackground(surface(card,20,0xff445654));
        linkState.setPadding(dp(13),dp(5),dp(13),dp(5)); header.addView(linkState);
        LinearLayout body=new LinearLayout(this); body.setOrientation(wide?0:1); insert(root,body,14,-2);
        LinearLayout monitor=column(); monitor.setBackground(surface(0xff203231,20,0xff39514c));
        monitor.setPadding(dp(18),dp(14),dp(18),dp(12));
        monitor.addView(label("INPUT MONITOR",12,lime,true));
        controllerName=label("",20,white,true); insert(monitor,controllerName,3,-2);
        scope=new Scope(); insert(monitor,scope,6,wide?145:116);
        latency=label("Receiver RTT  ·  —",14,soft,true); insert(monitor,latency,2,-2);
        LinearLayout form=column(); form.setPadding(dp(18),dp(16),dp(18),dp(16)); form.setBackground(surface(card,20,0xff344140));
        LinearLayout formHeader = new LinearLayout(this);
        formHeader.setGravity(Gravity.CENTER_VERTICAL);
        formHeader.addView(label("Pair receiver",23,white,true),new LinearLayout.LayoutParams(0,-2,1));
        Button profiles = new Button(this,null,android.R.attr.borderlessButtonStyle);
        profiles.setText("Profiles"); profiles.setTextColor(lime); profiles.setAllCaps(false);
        profiles.setOnClickListener(v -> showProfiles());
        formHeader.addView(profiles); form.addView(formHeader);
        LinearLayout addressColumn=form, codeColumn=form;
        if(wide){
            LinearLayout fields=new LinearLayout(this);
            addressColumn=column(); codeColumn=column();
            fields.addView(addressColumn,new LinearLayout.LayoutParams(0,-2,1.5f));
            LinearLayout.LayoutParams codeParams=new LinearLayout.LayoutParams(0,-2,1);
            codeParams.leftMargin=dp(8); fields.addView(codeColumn,codeParams);
            form.addView(fields);
        }
        host=field(addressColumn,"PC address","192.168.0.203",android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_URI);
        host.setText(getPreferences(0).getString("host",""));
        pin=field(codeColumn,"Pairing code","6 digits",android.text.InputType.TYPE_CLASS_NUMBER);
        pin.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(6)});
        connect=new Button(this); connect.setText("Connect"); connect.setAllCaps(false); connect.setTextColor(ink); connect.setTextSize(17);
        connect.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x44000000),surface(lime,12,0),null));
        insert(form,connect,16,50); status=label("Use the code shown on your PC.",14,soft,false);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE); insert(form,status,10,-2);
        if(wide){
            body.addView(monitor,new LinearLayout.LayoutParams(0,-2,1));
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1); p.leftMargin=dp(14); body.addView(form,p);
        }else{insert(body,monitor,0,-2);insert(body,form,12,-2);}
        setContentView(scroll); refreshDevice();
        host.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_NEXT | android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI);
        pin.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_DONE | android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI);
        pin.setOnEditorActionListener((v,action,event)->{if(action!=android.view.inputmethod.EditorInfo.IME_ACTION_DONE)return false; connect.performClick();return true;});
        connect.setOnClickListener(v -> {
            if (session != null) { stop("Disconnected"); return; }
            String ip = host.getText().toString().trim(), code = pin.getText().toString();
            if(ip.isEmpty() || !code.matches("[0-9]{6}")) { status.setText("Enter the PC address and six-digit code."); return; }
            getPreferences(0).edit().putString("host",ip).apply();
            session = new Session(ip,code); emit(); session.start();
            ((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(pin.getWindowToken(),0); host.setEnabled(false); pin.setEnabled(false); linkState.setText("Pairing…"); status.setText("Contacting receiver…"); connect.setText("Disconnect");
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        });
    }
    class Scope extends View {
        final android.graphics.Paint paint=new android.graphics.Paint(1);
        Scope(){super(Bridge.this);setContentDescription("Live controller diagram");}
        void dot(android.graphics.Canvas c,float x,float y,float r,int color){
            paint.setColor(color); c.drawCircle(x,y,r,paint);
        }
        void key(android.graphics.Canvas c,int x,int y,String text,int mask){
            boolean active=((buttons|hat)&mask)!=0;
            dot(c,x,y,10,active?lime:0xff37514d);
            paint.setColor(active?ink:white);paint.setTextSize(11);paint.setTextAlign(android.graphics.Paint.Align.CENTER);
            c.drawText(text,x,y+4,paint);
        }
        void stick(android.graphics.Canvas c,int x,int y,short dx,short dy){
            dot(c,x,y,19,0xff45625c);dot(c,x,y,17,ink);
            dot(c,x+dx/32767f*10,y-dy/32767f*10,7,lime);
        }
        protected void onDraw(android.graphics.Canvas c){
            float scale=Math.min(getWidth()/320f,getHeight()/118f);
            c.save();c.translate((getWidth()-320*scale)/2,(getHeight()-118*scale)/2);c.scale(scale,scale);
            paint.setColor(0xff131f20); c.drawRoundRect(6,15,314,113,30,30,paint);
            stick(c,54,47,lx,ly);stick(c,204,84,rx,ry);
            key(c,98,60,"↑",1);key(c,98,98,"↓",2);key(c,79,79,"‹",4);key(c,117,79,"›",8);
            key(c,260,32,"Y",32768);key(c,240,52,"X",16384);key(c,280,52,"B",8192);key(c,260,72,"A",4096);
            for(int i=0;i<2;i++){
                int x=i==0?28:230;
                paint.setColor(0xff47615a);c.drawRoundRect(x,6,x+62,12,3,3,paint);
                int v=i==0?(lbTrigger?255:lt):(rbTrigger?255:rt);
                paint.setColor(lime);c.drawRoundRect(x,6,x+62*v/255f,12,3,3,paint);
            }
            c.restore();
        }
    }
    class Session extends Thread {
        final String address, code;
        final Socket socket = new Socket();
        final BlockingQueue<byte[]> frames = new ArrayBlockingQueue<>(128);
        volatile boolean supportsRtt;
        volatile long sentAt;
        void readAcks(DataInputStream in){
            try{
                if(in.readUnsignedByte()!=82) return; // R advertises RTT support.
                supportsRtt=true;
                while(in.readUnsignedByte()==65){
                    long elapsed=System.nanoTime()-sentAt;
                    sentAt=0;
                    String value=String.format(java.util.Locale.getDefault(),"Receiver RTT  ·  %.1f ms",elapsed/1_000_000.0);
                    runOnUiThread(()->{if(session==this) latency.setText(value);});
                }
            } catch(IOException ignored) {
                // Closing the session also releases this blocking reader.
            }
        }
        Session(String a,String c){address=a; code=c;}
        public void run(){
            try(Socket s = socket) {
                s.connect(new InetSocketAddress(address,26760),3000);
                s.setTcpNoDelay(true); s.setSoTimeout(3000);
                OutputStream out=s.getOutputStream();
                out.write(("KSH1"+code).getBytes("US-ASCII"));
                DataInputStream in=new DataInputStream(s.getInputStream());
                if(in.readUnsignedShort()!=0x4f4b) throw new IOException("Pairing rejected");
                runOnUiThread(() -> {if(session==this){linkState.setText("Connected"); linkState.setTextColor(lime); status.setText("Sending input to "+address);}});
                s.setSoTimeout(0);
                new Thread(()->readAcks(in),"Kishi RTT reader").start();
                long nextProbe=System.nanoTime();
                byte[] last=new byte[12];
                while(!isInterrupted()){
                    byte[] next=frames.poll(100,TimeUnit.MILLISECONDS);
                    if(next!=null) last=next;
                    long now=System.nanoTime();
                    if(supportsRtt && sentAt==0 && now-nextProbe>=0){
                        byte[] probe=last.clone();
                        probe[0]|=0x08;
                        sentAt=System.nanoTime();
                        out.write(probe);
                        nextProbe=now+TimeUnit.SECONDS.toNanos(1);
                    }else{
                        out.write(last);
                    }
                }
            } catch(Exception e){
                runOnUiThread(() -> {if(session==this) Bridge.this.stop(e instanceof EOFException ? "Pairing ended. Check the six-digit code on your PC." : "Receiver unavailable. Check the PC address, Wi-Fi and firewall.");});
            }
        }
    }
    void stop(String message){
        Session old=session; session=null;
        if(old!=null){old.interrupt(); try{old.socket.close();}catch(IOException ignored){}}
        device=-1; buttons=hat=lt=rt=0; lbTrigger=rbTrigger=false; lx=ly=rx=ry=0;
        latency.setText("Receiver RTT  ·  —"); scope.invalidate(); host.setEnabled(true); pin.setEnabled(true); linkState.setText("Offline"); linkState.setTextColor(white); connect.setText("Connect"); status.setText(message);
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }
    void emit(){
        scope.postInvalidateOnAnimation(); if(session==null) return;
        byte[] frame=ByteBuffer.allocate(12).putShort((short)(buttons|hat))
            .put((byte)(lbTrigger?255:lt)).put((byte)(rbTrigger?255:rt))
            .putShort(lx).putShort(ly).putShort(rx).putShort(ry).array();
        if(!session.frames.offer(frame)) stop("Network stalled. Reconnect to resume.");
    }
    boolean accepts(InputEvent e){
        InputDevice d=e.getDevice();
        if(d==null || !(d.supportsSource(InputDevice.SOURCE_GAMEPAD)||d.supportsSource(InputDevice.SOURCE_JOYSTICK))) return false;
        if(device==-1) device=d.getId();
        return device==d.getId();
    }
    public boolean dispatchKeyEvent(KeyEvent e){
        if(!accepts(e)) return super.dispatchKeyEvent(e);
        boolean down=e.getAction()==KeyEvent.ACTION_DOWN;
        int mask;
        switch(e.getKeyCode()){
            case 96:mask=4096;break; case 97:mask=8192;break; case 99:mask=16384;break; case 100:mask=32768;break;
            case 102:mask=256;break; case 103:mask=512;break; case 106:mask=64;break; case 107:mask=128;break;
            case 108:mask=16;break; case 109:mask=32;break;
            case 19:mask=1;break; case 20:mask=2;break; case 21:mask=4;break; case 22:mask=8;break;
            case 104:lbTrigger=down;mask=0;break; case 105:rbTrigger=down;mask=0;break;
            default:return super.dispatchKeyEvent(e);
        }
        buttons=down?(buttons|mask):(buttons&~mask); emit(); return true;
    }
    short stick(MotionEvent e,int axis,int sign){
        float v=e.getAxisValue(axis);
        InputDevice.MotionRange r=e.getDevice().getMotionRange(axis,e.getSource());
        if(r!=null && Math.abs(v)<=r.getFlat()) return 0;
        return (short)Math.round(Math.max(-1,Math.min(1,v))*sign*32767);
    }
    int trigger(MotionEvent e,int a,int b){
        return Math.round(255*Math.max(0,Math.min(1,Math.max(e.getAxisValue(a),e.getAxisValue(b)))));
    }
    public boolean onGenericMotionEvent(MotionEvent e){
        if(!e.isFromSource(InputDevice.SOURCE_JOYSTICK)||!accepts(e)) return super.onGenericMotionEvent(e);
        lx=stick(e,MotionEvent.AXIS_X,1); ly=stick(e,MotionEvent.AXIS_Y,-1);
        rx=stick(e,MotionEvent.AXIS_Z,1); ry=stick(e,MotionEvent.AXIS_RZ,-1);
        lt=trigger(e,MotionEvent.AXIS_LTRIGGER,MotionEvent.AXIS_BRAKE);
        rt=trigger(e,MotionEvent.AXIS_RTRIGGER,MotionEvent.AXIS_GAS);
        float x=e.getAxisValue(MotionEvent.AXIS_HAT_X), y=e.getAxisValue(MotionEvent.AXIS_HAT_Y);
        hat=(x<0?4:x>0?8:0)|(y<0?1:y>0?2:0); emit(); return true;
    }
    public void onInputDeviceAdded(int id){refreshDevice();}
    public void onInputDeviceChanged(int id){refreshDevice();}
    public void onInputDeviceRemoved(int id){if(device==id) stop("Controller detached");refreshDevice();}
    protected void onResume(){super.onResume(); refreshDevice(); getSystemService(InputManager.class).registerInputDeviceListener(this,null);}
    protected void onPause(){getSystemService(InputManager.class).unregisterInputDeviceListener(this); stop("Disconnected"); super.onPause();}
}







