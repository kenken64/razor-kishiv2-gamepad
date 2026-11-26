package net.kishi.bridge;

import com.google.zxing.BinaryBitmap;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.ReaderException;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class PairingQr {
    private static final Pattern FORMAT = Pattern.compile(
        "kishi://pair/([0-9]{1,3}(?:\\.[0-9]{1,3}){3})/([0-9]{6})");
    final String address;
    final String code;

    private PairingQr(String address, String code) {
        this.address = address;
        this.code = code;
    }

    static PairingQr parse(String text) {
        if (text == null) return null;
        Matcher match = FORMAT.matcher(text);
        if (!match.matches()) return null;
        for (String part : match.group(1).split("\\."))
            if (Integer.parseInt(part) > 255 || (part.length() > 1 && part.startsWith("0"))) return null;
        return new PairingQr(match.group(1), match.group(2));
    }

    static String decode(byte[] frame, int width, int height) throws ReaderException {
        PlanarYUVLuminanceSource image = new PlanarYUVLuminanceSource(frame,width,height,0,0,width,height,false);
        return new QRCodeReader().decode(new BinaryBitmap(new HybridBinarizer(image))).getText();
    }
}
