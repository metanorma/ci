#!/usr/bin/env python

import os
import platform
import xml.etree.ElementTree as ET
import xml.dom.minidom as minidom

home_path = os.path.expanduser("~")
esp_share_path = "share/inkscape/extensions/eps_input.inx"
eps_input_paths = {
  "Darwin": [
    os.path.join("/Applications/Inkscape.app/Contents/Resources",
                 esp_share_path),
    os.path.join("/usr", esp_share_path)
  ],
  "Windows": [
    os.path.join("C:\\Program Files\\Inkscape", esp_share_path),
    os.path.join(home_path, "AppData\\Roaming\\inkscape\\eps_input.inx")
  ],
  "Linux": [os.path.join("/usr", esp_share_path)]
}.get(platform.system(), [])

default_ns = "http://www.inkscape.org/namespace/inkscape/extension"

ET.register_namespace("", default_ns)

for eps_input_path in eps_input_paths:
    if not os.path.exists(eps_input_path):
        print("{} doesn't exists. Skip".format(eps_input_path))
        continue

    tree = ET.parse(eps_input_path)
    root = tree.getroot()

    print("{} before processing:".format(eps_input_path))
    print(minidom.parseString(ET.tostring(root)).toprettyxml(indent="  "))

    orig_param = tree.find("./param[@name='autorotate']",
                           namespaces={"": default_ns})
    if orig_param is not None:
        root.remove(orig_param)
        print("Original autorotate param {} removed".format(orig_param))

    new_param = ET.Element("param",
                           attrib={"name": "autorotate",
                                   "type": "string", "gui-hidden": "true"})
    new_param.text = "None"
    root.append(new_param)

    tree.write(eps_input_path)

    print("{} after processing:".format(eps_input_path))
    print(minidom.parseString(ET.tostring(root)).toprettyxml())
