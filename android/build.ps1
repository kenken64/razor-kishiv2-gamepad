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
    Run javac @('--release','8','-classpath',$api,'-d','build/classes','Bridge.java')
    Run jar @('cf','build/classes.jar','-C','build/classes','.')
    Run "$bt/d8.bat" @('--lib',$api,'--min-api','23','--output','build/dex','build/classes.jar')
    Run "$bt/aapt.exe" @('package','-f','-M','AndroidManifest.xml','-S','res','-I',$api,'-F','build/raw.apk')
    Push-Location build/dex
    try { Run "$bt/aapt.exe" @('add','../raw.apk','classes.dex') } finally { Pop-Location }
    Run "$bt/zipalign.exe" @('-f','4','build/raw.apk','build/aligned.apk')
    if (!(Test-Path build/debug.jks)) {
        Run keytool @('-genkeypair','-keystore','build/debug.jks','-storepass','android','-keypass','android','-alias','debug','-keyalg','RSA','-validity','10000','-dname','CN=Kishi Local Debug')
    }
    Run "$bt/apksigner.bat" @('sign','--ks','build/debug.jks','--ks-pass','pass:android','--out','build/Kishi-WiFi.apk','build/aligned.apk')
    Run "$bt/apksigner.bat" @('verify','build/Kishi-WiFi.apk')
} finally { Pop-Location }
