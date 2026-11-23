package net.kishi.bridge;

/** Converts the sender's big-endian Xbox state into a generic Android HID gamepad. */
final class GamepadReport {
    static final String NAME = "Kishi Wi-Fi Gamepad";
    // Button usages follow Android's standard gamepad layout. Hat 8 denotes center.
    static final int[] DESCRIPTOR = {
        0x05,1, 0x09,5, 0xa1,1,
        0x05,9, 0x19,1, 0x29,15, 0x15,0, 0x25,1, 0x75,1, 0x95,15, 0x81,2,
        0x95,1, 0x81,3,
        0x05,1, 0x09,0x39, 0x15,0, 0x25,7, 0x35,0, 0x46,0x3b,1,
        0x65,0x14, 0x75,4, 0x95,1, 0x81,0x42, 0x65,0, 0x81,3,
        0x09,0x30, 0x09,0x31, 0x09,0x32, 0x09,0x35,
        0x16,1,0x80, 0x26,0xff,0x7f, 0x36,1,0x80, 0x46,0xff,0x7f,
        0x75,16, 0x95,4, 0x81,2,
        0x05,2, 0x09,0xc5, 0x09,0xc4, 0x15,0, 0x26,0xff,0, 0x35,0, 0x46,0xff,0,
        0x75,8, 0x95,2, 0x81,2, 0xc0
    };
    static final int[] MASKS = {4096,8192,0,16384,32768,0,256,512,0,0,32,16,0,64,128};
    static int[] convert(byte[] frame) {
        int flags = ((frame[0] & 255) << 8) | (frame[1] & 255);
        int buttons = 0;
        for (int i=0; i<MASKS.length; i++) if ((flags & MASKS[i]) != 0) buttons |= 1 << i;
        int x = ((flags >> 3) & 1) - ((flags >> 2) & 1);
        int y = ((flags >> 1) & 1) - (flags & 1);
        int[] hats = {7,0,1,6,8,2,5,4,3};
        int[] hid = new int[13];
        hid[0]=buttons & 255; hid[1]=buttons >> 8; hid[2]=hats[(y+1)*3+x+1];
        for (int i=0; i<4; i++) {
            int axis=(short)((frame[4+2*i] << 8) | (frame[5+2*i] & 255));
            axis=Math.max(-32767,axis);
            if ((i & 1)!=0) axis=-axis;
            hid[3+2*i]=axis & 255; hid[4+2*i]=(axis >> 8) & 255;
        }
        hid[11]=frame[2] & 255; hid[12]=frame[3] & 255;
        return hid;
    }
}
