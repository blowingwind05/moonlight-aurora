// SPDX-License-Identifier: GPL-3.0-only
import QtQuick 2.12
import QtQuick.Controls 2.12

Rectangle {
    id: stage
    color: "#F9FAFC"

    property bool connecting: true
    property bool failed: false
    property bool offerQuit: false
    property bool reduceMotion: false
    property string heading: qsTr("正在连接…")
    property string detail: ""
    readonly property string uiFont: Qt.platform.os === "windows" ? "Microsoft YaHei UI"
        : Qt.platform.os === "osx" ? "PingFang SC" : Qt.application.font.family

    signal retryRequested()
    signal quitPreviousRequested()

    Column {
        width: Math.max(0, Math.min(420, parent.width - 40))
        anchors.centerIn: parent
        spacing: 10

        Item {
            width: 26
            height: 26
            anchors.horizontalCenter: parent.horizontalCenter
            visible: stage.connecting
            Accessible.ignored: true

            Rectangle {
                anchors.fill: parent
                radius: 13
                color: "transparent"
                border.width: 2
                border.color: "#D4E0F2"
            }

            Canvas {
                anchors.fill: parent
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    ctx.strokeStyle = "#087CF5"
                    ctx.lineWidth = 2
                    ctx.lineCap = "round"
                    ctx.beginPath()
                    ctx.arc(width / 2, height / 2, width / 2 - 1, -Math.PI / 2, 0)
                    ctx.stroke()
                }

                NumberAnimation on rotation {
                    from: 0
                    to: 360
                    duration: 850
                    loops: Animation.Infinite
                    running: stage.visible && stage.connecting && !stage.reduceMotion
                }
            }
        }

        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: stage.heading
            elide: Text.ElideRight
            color: "#19283F"
            font.family: stage.uiFont
            font.pixelSize: 18
            font.weight: Font.DemiBold
            Accessible.description: stage.connecting ? stage.detail : ""
            ToolTip.text: stage.detail
            ToolTip.visible: hover.hovered && stage.connecting && stage.detail.length > 0
            ToolTip.delay: 600

            HoverHandler { id: hover }
        }

        ScrollView {
            id: details
            width: parent.width
            height: visible ? Math.min(86, description.implicitHeight) : 0
            visible: !stage.connecting && stage.detail.length > 0
            clip: true
            contentWidth: availableWidth
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            TextArea {
                id: description
                width: details.availableWidth
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                horizontalAlignment: Text.AlignHCenter
                text: stage.detail
                textFormat: TextEdit.PlainText
                font.family: stage.uiFont
                font.pixelSize: 13
                color: "#526176"
                padding: 2
                background: null
                onTextChanged: cursorPosition = 0
            }
        }

        Button {
            id: actionButton
            objectName: "sessionAction"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: stage.failed || stage.offerQuit
            height: 32
            leftPadding: 16
            rightPadding: 16
            text: stage.failed ? qsTr("重试") : qsTr("退出应用")
            font.family: stage.uiFont
            font.pixelSize: 13
            font.weight: Font.DemiBold
            onClicked: {
                if (stage.failed)
                    stage.retryRequested()
                else
                    stage.quitPreviousRequested()
            }

            contentItem: Text {
                text: actionButton.text
                font: actionButton.font
                color: "white"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            background: Rectangle {
                radius: 7
                color: actionButton.down ? "#175CB7" : actionButton.hovered ? "#076BD7" : "#087CF5"
                border.width: actionButton.visualFocus ? 1 : 0
                border.color: "#19283F"
            }
        }
    }

    Shortcut {
        sequence: "Return"
        enabled: stage.visible && stage.failed
        onActivated: stage.retryRequested()
    }
}
