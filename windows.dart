import 'dart:io';

void main() {
  final versionStr = Platform.environment['VERSION']!;
  final issPath = 'build/windows/recipe-manager-$versionStr.iss';

  _writeIssFile(issPath, versionStr);
  _compile(issPath);
}

void _writeIssFile(String issPath, String versionStr) {
  final iss = '''
[Setup]
AppName=Recipe Manager
AppVersion=$versionStr
AppPublisher=SharpBlue
AppPublisherURL=https://sharpblue.com.au/
AppSupportURL=https://sharpblue.com.au/
AppUpdatesURL=https://sharpblue.com.au/
DefaultDirName={autopf}\\Recipe Manager
DefaultGroupName=Recipe Manager
OutputDir=.
OutputBaseFilename=recipe-manager-$versionStr
SetupIconFile=..\\..\\windows\\runner\\resources\\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "x64\\runner\\Release\\recipe_manager.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "x64\\runner\\Release\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\\Recipe Manager"; Filename: "{app}\\recipe_manager.exe"
Name: "{group}\\Uninstall Recipe Manager"; Filename: "{uninstallexe}"
Name: "{autodesktop}\\Recipe Manager"; Filename: "{app}\\recipe_manager.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\\recipe_manager.exe"; Description: "{cm:LaunchProgram,Recipe Manager}"; Flags: nowait postinstall skipifsilent
''';

  File(issPath).writeAsStringSync(iss);
}

void _compile(String issPath) {
  try {
    const iscc = 'iscc';
    final result = Process.runSync(iscc, [issPath], runInShell: true);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      throw ProcessException(iscc, [issPath], 'iscc failed with exit code ${result.exitCode}', result.exitCode);
    }
    print('Done.');
  } catch (e, s) {
    print('Failed: $e\n$s');
  }
}
