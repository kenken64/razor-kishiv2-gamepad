param([string]$Sdk = 'D:\Android\Sdk')
$ErrorActionPreference = 'Stop'
function Run($tool, [string[]]$arguments) {
    & $tool @arguments
    if ($LASTEXITCODE) { throw "$tool failed ($LASTEXITCODE)" }
}
Push-Location $PSScriptRoot
try {
    $bt = "$Sdk/build-tools/35.0.0"
    $api = "$Sdk/platforms/android-35/android.jar"
    New-Item -ItemType Directory -Force build/classes,build/dex | Out-Null
    $zxing = 'build/core-3.3.3.jar'
    if (!(Test-Path -LiteralPath $zxing)) {
        Invoke-WebRequest -UseBasicParsing -Uri 'https://repo.maven.apache.org/maven2/com/google/zxing/core/3.3.3/core-3.3.3.jar' -OutFile $zxing
    }
    if ((Get-FileHash -Algorithm SHA256 $zxing).Hash -ne '5820F81E943E4BCE0329306621E2D6255D2930B0A6CE934C5C23C0D6D3F20599') {
        throw "Invalid ZXing dependency. Remove $zxing and rebuild."
    }
    Run javac @('-encoding','UTF-8','--release','8','-classpath',"$api;$zxing",'-d','build/classes','Bridge.java','PairingQr.java','PairingScanActivity.java','ReceiverActivity.java','ReceiverService.java','GamepadHelper.java','GamepadReport.java','ReceiverProtocol.java','HelperLink.java','HelperSetup.java')
    Run jar @('cf','build/classes.jar','-C','build/classes','.')
    Run "$bt/d8.bat" @('--lib',$api,'--min-api','23','--output','build/dex','build/classes.jar',$zxing)
    Run "$bt/aapt.exe" @('package','-f','-M','AndroidManifest.xml','-S','res','-A','assets','-I',$api,'-F','build/raw.apk')
    Push-Location build/dex
    try { Run "$bt/aapt.exe" @('add','../raw.apk','classes.dex') } finally { Pop-Location }
    Run "$bt/zipalign.exe" @('-f','4','build/raw.apk','build/aligned.apk')
    if (!(Test-Path build/debug.jks)) {
        Run keytool @('-genkeypair','-keystore','build/debug.jks','-storepass','android','-keypass','android','-alias','debug','-keyalg','RSA','-validity','10000','-dname','CN=PadRelay Local Debug')
    }
    Run "$bt/apksigner.bat" @('sign','--ks','build/debug.jks','--ks-pass','pass:android','--out','build/PadRelay.apk','build/aligned.apk')
    Run "$bt/apksigner.bat" @('verify','build/PadRelay.apk')
} finally { Pop-Location }
