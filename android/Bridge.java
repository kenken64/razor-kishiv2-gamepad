package net.kishi.bridge;

import android.app.Activity;
import android.graphics.Rect;
import android.os.Build;
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
    ImageButton scan;
    static final int SCAN_PAIRING = 14;
    TextView status;
    Session session;
    android.app.AlertDialog disconnectDialog;
    boolean pairedThisRun;
    int retrySeconds = 1;
    String resumeAddress, resumeCode;
    final android.os.Handler retryHandler = new android.os.Handler(android.os.Looper.getMainLooper());
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
    EditText field(LinearLayout parent,String name,String example,int type,View action,boolean inlineLabel){
        TextView caption=label(name,14,white,true);
        if(!inlineLabel) insert(parent,caption,4,-2);
        EditText input=new EditText(this); input.setId(View.generateViewId()); caption.setLabelFor(input.getId());
        input.setSingleLine(); input.setInputType(type); input.setTextSize(17);
        int[] disabled = {-android.R.attr.state_enabled};
        input.setTextColor(new android.content.res.ColorStateList(
            new int[][]{disabled, new int[0]}, new int[]{soft, white}));
        input.setHint(example); input.setHintTextColor(soft); input.setPadding(dp(8),0,dp(6),0);
        android.graphics.drawable.StateListDrawable states=new android.graphics.drawable.StateListDrawable();
        states.addState(disabled,surface(card,12,0));
        states.addState(new int[]{android.R.attr.state_focused},surface(ink,12,lime));
        states.addState(new int[]{},surface(ink,12,0xff445654)); input.setBackground(states);
        if(action==null && !inlineLabel) {
            insert(parent,input,2,48);
        } else {
            LinearLayout row=new LinearLayout(this);
            row.setGravity(Gravity.CENTER_VERTICAL);
            if(inlineLabel) row.addView(caption,new LinearLayout.LayoutParams(dp(76),-2));
            row.addView(input,new LinearLayout.LayoutParams(0,-1,1));
            if(action!=null) {
                LinearLayout.LayoutParams buttonParams=new LinearLayout.LayoutParams(dp(48),dp(48));
                buttonParams.setMarginStart(dp(6));
                row.addView(action,buttonParams);
            }
            insert(parent,row,2,48);
        }
        return input;
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
        if (rows.length == 0) dialog.setMessage("Save your receiver address under a name to use it again.");
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

    void revealFocusedField(){
        View focused=getCurrentFocus();
        if(focused!=host && focused!=pin) return;
        Rect bounds=new Rect();
        focused.getDrawingRect(bounds);
        bounds.inset(0,-dp(4));
        focused.requestRectangleOnScreen(bounds,false);
    }

    @android.annotation.TargetApi(30)
    void configureEdgeToEdge(View screen){
        Window window=getWindow();
        window.setDecorFitsSystemWindows(false);
        window.setStatusBarColor(0x00000000); window.setNavigationBarColor(0x00000000);
        WindowInsetsController controller=window.getInsetsController();
        if(controller!=null) controller.setSystemBarsAppearance(0,
            WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS|WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS);
        screen.setOnApplyWindowInsetsListener((v,insets)->{
            android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());
            android.graphics.Insets ime=insets.getInsets(WindowInsets.Type.ime());
            v.setPadding(bars.left,bars.top,bars.right,Math.max(bars.bottom,ime.bottom));
            if(ime.bottom>0) v.postDelayed(this::revealFocusedField,250);
            return insets;
        });
        screen.requestApplyInsets();
    }

    public void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().setStatusBarColor(ink); getWindow().setNavigationBarColor(ink);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
            | WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
        android.content.res.Configuration config=getResources().getConfiguration();
        boolean wide=config.orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE
            && config.screenWidthDp>=480;
        LinearLayout screen=column(); screen.setBackgroundColor(ink);
        ScrollView scroll=new ScrollView(this); scroll.setFillViewport(true); scroll.setVerticalScrollBarEnabled(false); scroll.setBackgroundColor(ink);
        screen.addView(scroll,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout root=column(); root.setPadding(dp(12),dp(2),dp(12),dp(2)); root.setFocusableInTouchMode(true); scroll.addView(root);
        LinearLayout header=new LinearLayout(this); header.setGravity(Gravity.CENTER_VERTICAL); root.addView(header);
        TextView title=label("Kishi Wi-Fi",25,white,true); title.setLetterSpacing(-0.045f);
        header.addView(title,new LinearLayout.LayoutParams(0,-2,1));
        Button receive=new Button(this,null,android.R.attr.borderlessButtonStyle);
        receive.setText("Receiver mode"); receive.setTextColor(lime); receive.setAllCaps(false);
        receive.setOnClickListener(v -> {
            if(session!=null) { Toast.makeText(this,"Disconnect before switching modes.",Toast.LENGTH_SHORT).show(); return; }
            getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
            ((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE))
                .hideSoftInputFromWindow(pin.getWindowToken(),0);
            pin.clearFocus(); host.clearFocus();
            startActivity(new android.content.Intent(this,ReceiverActivity.class));
        });
        header.addView(receive);
        linkState=label("Offline",13,white,true); linkState.setBackground(surface(card,20,0xff445654));
        linkState.setPadding(dp(13),dp(5),dp(13),dp(5)); header.addView(linkState);
        LinearLayout body=new LinearLayout(this); body.setOrientation(wide?0:1); insert(root,body,2,-2);
        LinearLayout monitor=column(); monitor.setBackground(surface(0xff203231,20,0xff39514c));
        monitor.setPadding(dp(10),dp(6),dp(10),dp(6));
        monitor.addView(label("INPUT MONITOR",12,lime,true));
        controllerName=label("",17,white,true); insert(monitor,controllerName,3,-2);
        scope=new Scope(); insert(monitor,scope,2,wide?Math.min(145,Math.max(64,config.screenHeightDp-196)):112);
        latency=label("Receiver RTT  ·  —",14,soft,true); insert(monitor,latency,2,-2);
        LinearLayout form=column(); form.setPadding(dp(10),dp(4),dp(10),dp(6)); form.setBackground(surface(card,20,0xff344140));
        LinearLayout formHeader = new LinearLayout(this);
        formHeader.setGravity(Gravity.CENTER_VERTICAL);
        formHeader.addView(label("Pair receiver",19,white,true),new LinearLayout.LayoutParams(0,-2,1));
        Button profiles = new Button(this,null,android.R.attr.borderlessButtonStyle);
        profiles.setText("Profiles"); profiles.setTextColor(lime); profiles.setAllCaps(false);
        profiles.setOnClickListener(v -> showProfiles());
        if(wide && config.screenHeightDp<320) header.addView(profiles,1);
        else formHeader.addView(profiles);
        form.addView(formHeader);
        LinearLayout addressColumn=form, codeColumn=form;
        if(config.screenWidthDp>=620){
            LinearLayout fields=new LinearLayout(this);
            addressColumn=column(); codeColumn=column();
            fields.addView(addressColumn,new LinearLayout.LayoutParams(0,-2,1));
            LinearLayout.LayoutParams codeParams=new LinearLayout.LayoutParams(0,-2,1);
            codeParams.leftMargin=dp(8); fields.addView(codeColumn,codeParams);
            form.addView(fields);
        }
        boolean inlineLabels=wide && config.screenWidthDp<620;
        host=field(addressColumn,"Receiver address","192.168.0.203",android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_URI,null,inlineLabels);
        host.setText(getPreferences(0).getString("host",""));
        scan=new ImageButton(this,null,android.R.attr.borderlessButtonStyle);
        scan.setImageResource(getResources().getIdentifier("ic_pair_qr","drawable",getPackageName()));
        scan.setImageTintList(new android.content.res.ColorStateList(
            new int[][]{{-android.R.attr.state_enabled},{}},new int[]{soft,lime}));
        scan.setContentDescription("Scan pairing QR code");
        if(Build.VERSION.SDK_INT>=26) scan.setTooltipText("Scan pairing QR code");
        scan.setOnClickListener(v -> startActivityForResult(
            new android.content.Intent(this,PairingScanActivity.class),SCAN_PAIRING));
        pin=field(codeColumn,"Pairing code","6 digits",android.text.InputType.TYPE_CLASS_NUMBER,scan,inlineLabels);
        pin.setFilters(new android.text.InputFilter[]{new android.text.InputFilter.LengthFilter(6)});
        connect=new Button(this);
        connect.setAllCaps(false);
        connect.setTextColor(ink);
        connect.setTextSize(16);
        connect.setPadding(dp(16),0,dp(16),0);
        connect.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x44000000),surface(lime,12,0),null));
        setConnectAction(false);
        insert(form,connect,6,48);
        status=label("Use the code shown on your receiver.",14,soft,false);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        insert(form,status,4,-2);
        if(wide){
            body.addView(monitor,new LinearLayout.LayoutParams(0,-2,0.82f));
            LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(0,-2,1); p.leftMargin=dp(8); body.addView(form,p);
        }else{insert(body,form,0,-2);insert(body,monitor,12,-2);}
        setContentView(screen); refreshDevice();
        if(Build.VERSION.SDK_INT>=30) configureEdgeToEdge(screen);
        View.OnFocusChangeListener reveal=(view,hasFocus)->{if(hasFocus) scroll.postDelayed(this::revealFocusedField,350);};
        host.setOnFocusChangeListener(reveal); pin.setOnFocusChangeListener(reveal);
        int noFullscreen=android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI
            | android.view.inputmethod.EditorInfo.IME_FLAG_NO_FULLSCREEN;
        host.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_NEXT | noFullscreen);
        pin.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_DONE | noFullscreen);
        pin.setOnEditorActionListener((v,action,event)->{if(action!=android.view.inputmethod.EditorInfo.IME_ACTION_DONE)return false; connect.performClick();return true;});
        connect.setOnClickListener(v -> {
            if (session != null) {
                confirmDisconnect();
                return;
            }
            String ip = host.getText().toString().trim(), code = pin.getText().toString();
            if(ip.isEmpty() || !code.matches("[0-9]{6}")) { status.setText("Enter the receiver address and six-digit code."); return; }
            getPreferences(0).edit().putString("host",ip).apply();
            beginAttempt(ip,code);
            ((android.view.inputmethod.InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(pin.getWindowToken(),0); linkState.setText("Pairing…"); status.setText("Contacting receiver…");
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        });
    }
    @Override protected void onActivityResult(int request,int result,android.content.Intent data) {
        super.onActivityResult(request,result,data);
        if (request!=SCAN_PAIRING || result!=RESULT_OK || data==null || session!=null) return;
        PairingQr pairing=PairingQr.parse(data.getStringExtra("pairing"));
        if (pairing==null) return;
        host.setText(pairing.address);
        pin.setText(pairing.code);
        status.setText("Receiver scanned. Tap Connect to pair.");
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
        void stick(android.graphics.Canvas c,int x,int y,short dx,short dy,String name,int mask){
            dot(c,x,y,19,(buttons&mask)!=0?lime:0xff45625c);dot(c,x,y,17,ink);
            dot(c,x+dx/32767f*10,y-dy/32767f*10,7,lime);
            paint.setTextAlign(android.graphics.Paint.Align.CENTER);paint.setTextSize(11);
            paint.setColor((buttons&mask)!=0?lime:white); c.drawText(name,x,y+31,paint);
        }
        protected void onDraw(android.graphics.Canvas c){
            float scale=Math.min(getWidth()/320f,getHeight()/143f);
            c.save();c.translate((getWidth()-320*scale)/2,(getHeight()-143*scale)/2);c.scale(scale,scale);c.translate(0,25);
            paint.setColor(0xff131f20); c.drawRoundRect(6,15,314,113,30,30,paint);
            stick(c,54,47,lx,ly,"L3",64);stick(c,204,79,rx,ry,"R3",128);
            key(c,98,60,"↑",1);key(c,98,98,"↓",2);key(c,79,79,"‹",4);key(c,117,79,"›",8);
            key(c,260,32,"Y",32768);key(c,240,52,"X",16384);key(c,280,52,"B",8192);key(c,260,72,"A",4096);
            for(int i=0;i<2;i++){
                int x=i==0?14:174;
                int v=i==0?(lbTrigger?255:lt):(rbTrigger?255:rt);
                boolean bumper=(buttons&(i==0?256:512))!=0;
                paint.setColor(bumper?lime:0xff37514d);c.drawRoundRect(x,-21,x+36,4,8,8,paint);
                paint.setTextAlign(android.graphics.Paint.Align.CENTER);paint.setTextSize(13);
                paint.setColor(bumper?ink:white);c.drawText(i==0?"LB":"RB",x+18,-4,paint);
                paint.setColor(v>0?lime:white);c.drawText(i==0?"LT":"RT",x+57,-4,paint);
                paint.setColor(0xff47615a);c.drawRoundRect(x+72,-12,x+130,-5,3,3,paint);
                paint.setColor(lime);c.drawRoundRect(x+72,-12,x+72+58*v/255f,-5,3,3,paint);
            }
            c.restore();
        }
    }
    void setConnectAction(boolean disconnect){
        String label=disconnect?"Disconnect":"Connect";
        String icon=disconnect?"ic_disconnect":"ic_connect";
        connect.setCompoundDrawablesRelativeWithIntrinsicBounds(getResources().getIdentifier(icon,"drawable",getPackageName()),0,0,0);
        connect.setText(label);
        connect.setContentDescription(label);
        if(Build.VERSION.SDK_INT>=26) connect.setTooltipText(label);
    }
    void beginAttempt(String address,String code){
        session = new Session(address,code);
        host.setEnabled(false); pin.setEnabled(false); scan.setEnabled(false); setConnectAction(true);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        session.start();
    }
    void retry(Session failed){
        if(session!=failed || failed.retryPending) return;
        failed.retryPending=true;
        failed.cancelAttempt();
        latency.setText("Receiver RTT  ·  —");
        linkState.setText("Reconnecting"); linkState.setTextColor(white);
        int delay=retrySeconds;
        retrySeconds=Math.min(8,delay*2);
        status.setText("Connection lost. Retrying in "+delay+" s…");
        retryHandler.postDelayed(()->{
            if(session==failed) beginAttempt(failed.address,failed.code);
        },delay*1000L);
    }
    class Session extends Thread {
        boolean ready, retryPending;
        void cancelAttempt(){
            interrupt();
            try{socket.close();}catch(IOException ignored){}
        }
        final String address, code;
        final Socket socket = new Socket();
        final BlockingQueue<byte[]> frames = new ArrayBlockingQueue<>(128);
        volatile boolean supportsRtt;
        volatile long sentAt;
        void readAcks(DataInputStream in){
            try{
                if(in.readUnsignedByte()!=82) return; // R advertises RTT support.
                supportsRtt=true;
                socket.setSoTimeout(5000); // A missed probe also detects silent network loss.
                while(in.readUnsignedByte()==65){
                    long elapsed=System.nanoTime()-sentAt;
                    sentAt=0;
                    String value=String.format(java.util.Locale.getDefault(),"Receiver RTT  ·  %.1f ms",elapsed/1_000_000.0);
                    runOnUiThread(()->{if(session==this && !retryPending) latency.setText(value);});
                }
            } catch(IOException ignored) {
                // EOF, reset, or a missing acknowledgement ends this attempt.
            } finally {
                try{socket.close();}catch(IOException ignored){}
            }
        }
        Session(String a,String c){address=a; code=c;}
        public void run(){
            boolean awaitingPair=false;
            try(Socket s = socket) {
                s.connect(new InetSocketAddress(address,26760),3000);
                s.setTcpNoDelay(true); s.setSoTimeout(3000);
                OutputStream out=s.getOutputStream();
                out.write(("KSH1"+code).getBytes("US-ASCII"));
                DataInputStream in=new DataInputStream(s.getInputStream());
                awaitingPair=true;
                if(in.readUnsignedShort()!=0x4f4b) throw new EOFException("Pairing rejected");
                awaitingPair=false;
                runOnUiThread(() -> {if(session==this && !retryPending){pairedThisRun=true; retrySeconds=1; ready=true; emit(); linkState.setText("Connected"); linkState.setTextColor(lime); status.setText("Sending input to "+address);}});
                s.setSoTimeout(0);
                new Thread(()->readAcks(in),"Kishi RTT reader").start();
                long nextProbe=System.nanoTime();
                byte[] last=frames.take();
                out.write(last);
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
                boolean rejected=awaitingPair && e instanceof EOFException;
                runOnUiThread(()->{
                    if(session!=this || retryPending) return;
                    if(rejected) Bridge.this.stop("Pairing declined. Enter the current code from the receiver.");
                    else if(pairedThisRun) retry(this);
                    else Bridge.this.stop("Receiver unavailable. Check the receiver address, Wi-Fi and firewall.");
                });
            }
        }
    }
    void confirmDisconnect(){
        if (disconnectDialog != null) return;
        disconnectDialog = new android.app.AlertDialog.Builder(this)
            .setTitle("Disconnect from receiver?")
            .setMessage("This will end the session and stop automatic reconnection.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Disconnect", (dialog, which) -> stop("Disconnected"))
            .create();
        disconnectDialog.setOnDismissListener(dialog -> disconnectDialog = null);
        disconnectDialog.show();
        disconnectDialog.getButton(android.app.AlertDialog.BUTTON_NEGATIVE).requestFocus();
    }
    void stop(String message){
        if (disconnectDialog != null) disconnectDialog.dismiss();
        Session old=session; session=null;
        retryHandler.removeCallbacksAndMessages(null);
        if(old!=null) old.cancelAttempt();
        pairedThisRun=false; retrySeconds=1;
        device=-1; buttons=hat=lt=rt=0; lbTrigger=rbTrigger=false; lx=ly=rx=ry=0;
        latency.setText("Receiver RTT  ·  —"); scope.invalidate(); host.setEnabled(true); pin.setEnabled(true); scan.setEnabled(true); linkState.setText("Offline"); linkState.setTextColor(white); setConnectAction(false); status.setText(message);
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }
    void emit(){
        scope.postInvalidateOnAnimation(); if(session==null || !session.ready || session.retryPending) return;
        byte[] frame=ByteBuffer.allocate(12).putShort((short)(buttons|hat))
            .put((byte)(lbTrigger?255:lt)).put((byte)(rbTrigger?255:rt))
            .putShort(lx).putShort(ly).putShort(rx).putShort(ry).array();
        if(!session.frames.offer(frame)) retry(session);
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
    protected void onResume(){super.onResume(); refreshDevice(); getSystemService(InputManager.class).registerInputDeviceListener(this,null);
        if(resumeAddress!=null){
            pairedThisRun=true;
            linkState.setText("Reconnecting"); status.setText("Restoring receiver connection…");
            beginAttempt(resumeAddress,resumeCode);
            resumeAddress=null; resumeCode=null;
        }
    }
    protected void onPause(){
        if(session!=null && pairedThisRun){resumeAddress=session.address; resumeCode=session.code;}
        getSystemService(InputManager.class).unregisterInputDeviceListener(this); stop("Disconnected"); super.onPause();}
}
