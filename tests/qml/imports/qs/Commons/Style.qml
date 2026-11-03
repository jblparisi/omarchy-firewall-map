pragma Singleton
import QtQuick
QtObject {
  property int cornerRadius: 4
  property var font: ({family: "sans-serif", caption: 12})
  function space(value) { return value }
}
