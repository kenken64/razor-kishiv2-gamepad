package net.kishi.bridge;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.ImageFormat;
import android.hardware.Camera;
import android.os.Bundle;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import com.google.zxing.ReaderException;
import java.io.IOException;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

@SuppressWarnings("deprecation")
public final class PairingScanActivity extends Activity implements SurfaceHolder.Callback {
    private static final int REQUEST_CAMERA = 1;
    private final ExecutorService decoder = Executors.newSingleThreadExecutor();
    private FrameLayout stage;
    private SurfaceView preview;
    private TextView hint;
    private Camera camera;
    private boolean resumed, surfaceReady;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(0xff101517);
        stage = new FrameLayout(this);
        preview = new SurfaceView(this);
        stage.addView(preview);
        root.addView(stage,new LinearLayout.LayoutParams(-1,0,1));
        LinearLayout bar = new LinearLayout(this);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        hint = new TextView(this);
        hint.setPadding(20,0,8,0);
        hint.setTextColor(0xffffffff);
        hint.setText("Point the camera at the receiver’s pairing QR code.");
        bar.addView(hint,new LinearLayout.LayoutParams(0,-2,1));
        Button cancel = new Button(this);
        cancel.setText("Cancel");
        cancel.setOnClickListener(v -> finish());
        bar.addView(cancel);
        root.addView(bar);
        setContentView(root);
        preview.getHolder().addCallback(this);
        if (state == null && checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(new String[]{Manifest.permission.CAMERA},REQUEST_CAMERA);
    }

    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(request,permissions,grants);
        if (request != REQUEST_CAMERA) return;
        if (grants.length == 0 || grants[0] != PackageManager.PERMISSION_GRANTED)
            fail("Camera access is needed to scan. You can still enter the code manually.");
        else startCamera();
    }

    @Override protected void onResume() { super.onResume(); resumed=true; startCamera(); }
    @Override protected void onPause() { resumed=false; closeCamera(); super.onPause(); }
    @Override protected void onDestroy() { decoder.shutdownNow(); super.onDestroy(); }
    @Override public void surfaceCreated(SurfaceHolder holder) { surfaceReady=true; startCamera(); }
    @Override public void surfaceChanged(SurfaceHolder holder,int format,int w,int h) {}
    @Override public void surfaceDestroyed(SurfaceHolder holder) { surfaceReady=false; closeCamera(); }

    private void startCamera() {
        if (!resumed || !surfaceReady || camera != null || isFinishing() ||
                checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return;
        try {
            Camera.CameraInfo info = new Camera.CameraInfo();
            int count=Camera.getNumberOfCameras(), id=0;
            if (count==0) { fail("No camera available. Enter the pairing code manually."); return; }
            for (int i=0;i<count;i++) {
                Camera.getCameraInfo(i,info);
                if (info.facing==Camera.CameraInfo.CAMERA_FACING_BACK) { id=i; break; }
            }
            Camera.getCameraInfo(id,info);
            camera=Camera.open(id);
            Camera.Parameters params=camera.getParameters();
            Camera.Size size=params.getPreviewSize();
            int best=Integer.MAX_VALUE;
            for (Camera.Size candidate : params.getSupportedPreviewSizes()) {
                int difference=Math.abs(candidate.width*candidate.height-1280*720);
                if (difference<best) { best=difference; size=candidate; }
            }
            params.setPreviewSize(size.width,size.height);
            params.setPreviewFormat(ImageFormat.NV21);
            List<String> focus=params.getSupportedFocusModes();
            if (focus!=null && focus.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE))
                params.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
            camera.setParameters(params);
            int rotation=getWindowManager().getDefaultDisplay().getRotation()*90;
            int angle=info.facing==Camera.CameraInfo.CAMERA_FACING_FRONT
                ? (360-(info.orientation+rotation)%360)%360 : (info.orientation-rotation+360)%360;
            camera.setDisplayOrientation(angle);
            int w=angle%180==0 ? size.width : size.height;
            int h=angle%180==0 ? size.height : size.width;
            double scale=Math.min(stage.getWidth()/(double)w,stage.getHeight()/(double)h);
            if (scale>0) preview.setLayoutParams(new FrameLayout.LayoutParams(
                (int)Math.round(w*scale),(int)Math.round(h*scale),Gravity.CENTER));
            camera.setPreviewDisplay(preview.getHolder());
            camera.startPreview();
            nextFrame(camera,size.width,size.height);
        } catch (IOException | RuntimeException e) { closeCamera(); fail("Camera unavailable. Enter the pairing code manually."); }
    }

    private void nextFrame(Camera active,int width,int height) {
        if (camera!=active || isFinishing()) return;
        active.setOneShotPreviewCallback((data,source) -> {
            if (camera!=source) return;
            if (data==null) {
                preview.postDelayed(() -> nextFrame(source,width,height),70);
                return;
            }
            decoder.execute(() -> {
                String result=null;
                try { result=PairingQr.decode(data,width,height); } catch (ReaderException ignored) {}
                final String text=result;
                runOnUiThread(() -> {
                    if (camera!=source || isFinishing()) return;
                    if (PairingQr.parse(text)!=null) {
                        setResult(RESULT_OK,new Intent().putExtra("pairing",text));
                        finish();
                    } else {
                        if (text!=null) hint.setText("Use the pairing QR code shown by PadRelay.");
                        preview.postDelayed(() -> nextFrame(source,width,height),70);
                    }
                });
            });
        });
    }

    private void closeCamera() {
        Camera active=camera;
        camera=null;
        if (active!=null) active.release();
    }

    private void fail(String message) {
        Toast.makeText(this,message,Toast.LENGTH_LONG).show();
        finish();
    }
}
