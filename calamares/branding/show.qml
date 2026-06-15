cat > calamares/branding/show.qml << 'EOF'
import QtQuick 2.0;
Image {
    id: background
    source: "images/performance-gains.jpg"
    fillMode: Image.PreserveAspectCrop
    width: parent.width
    height: parent.height
}
EOF
