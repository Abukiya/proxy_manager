import QtQuick
import QtQuick.Shapes
import qs.Commons

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    ShapePath {
      fillColor: "transparent"
      strokeColor: root.color
      strokeWidth: Math.max(1.5, root.iconSize * 0.12)
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      startX: root.width * 0.5
      startY: root.height * 0.08
      PathLine { x: root.width * 0.84; y: root.height * 0.22 }
      PathLine { x: root.width * 0.80; y: root.height * 0.62 }
      PathLine { x: root.width * 0.5; y: root.height * 0.90 }
      PathLine { x: root.width * 0.20; y: root.height * 0.62 }
      PathLine { x: root.width * 0.16; y: root.height * 0.22 }
      PathLine { x: root.width * 0.5; y: root.height * 0.08 }
    }
  }

  Rectangle {
    width: Math.max(3, root.iconSize * 0.22)
    height: width
    radius: width / 2
    color: root.color
    x: root.width * 0.5 - width / 2
    y: root.height * 0.49 - height / 2
  }
}
