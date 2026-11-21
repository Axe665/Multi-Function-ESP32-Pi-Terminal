import QtQuick
import QtQuick.Controls

ApplicationWindow {
    visible: true
    width: 1024; height: 680
    minimumWidth: 720; minimumHeight: 460
    title: "啸天 · 红外栏杆调试基线"
    color: "#101b29"
    ModulePage { anchors.fill: parent; backend: irController }
}
