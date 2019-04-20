#!/usr/bin/env sh
wget "http://downloads.sourceforge.net/project/plantuml/plantuml.jar?r=&ts=1424308684&use_mirror=jaist" -O plantuml.jar
sudo mkdir -p /opt/plantuml
sudo cp plantuml.jar /opt/plantuml
echo '#!/usr/bin/env sh' > plantuml.sh
echo 'exec java -jar /opt/plantuml/plantuml.jar "$@"' >> plantuml.sh
sudo install -m 755 plantuml.sh /usr/local/bin/plantuml
plantuml -version
