& choco install --no-progress --x86 xsltproc
& choco install --no-progress plantuml make sed gnuwin32-coreutils.install
& npm i -g puppeteer

Set-Content $Env:ChocolateyInstall\bin\xml2-config.bat "@ECHO OFF" -Encoding ASCII
Set-Content $Env:ChocolateyInstall\bin\xslt-config.bat "@ECHO OFF" -Encoding ASCII

$XsltDist = ${Env:ChocolateyInstall} + "\lib\xsltproc\dist"
$XsltInclude = $XsltDist + "\include"
$XsltLib = $XsltDist + "\lib"

# FIXME remove once ruby-xslt will be elimiated from our dependencies
if ($Env:RUBY_VERSION -eq "23") {
	Copy-Item -Force $XsltDist\bin\lib*.dll C:\Ruby${Env:RUBY_VERSION}\bin\
} else {
	# Copy with removing version from filename (need because xslt_lib.so expect such names)
	Copy-Item -Force $XsltDist\bin\libxml2-*.dll $XsltDist\bin\libxml2.dll
	Copy-Item -Force $XsltDist\bin\libxslt-*.dll $XsltDist\bin\libxslt.dll
	Copy-Item -Force $XsltDist\bin\libexslt-*.dll $XsltDist\bin\libexslt.dll

	[Environment]::SetEnvironmentVariable("RUBY_DLL_PATH", "${Env:ChocolateyInstall}\lib\xsltproc\dist\bin;${Env:RUBY_DLL_PATH}", [System.EnvironmentVariableTarget]::Machine)
}

# 'bundle config build.ruby-xslt' doesn't work of windows for some reason
$RubyBin = "C:\Ruby${Env:RUBY_VERSION}\bin"
& $RubyBin\gem.cmd install bundler
& $RubyBin\gem.cmd install ruby-xslt -- `
  --with-xml2-include=$XsltInclude\libxml2 `
  --with-xslt-include=$XsltInclude `
  --with-xml2-lib=$XsltLib `
  --with-xslt-lib=$XsltLib
