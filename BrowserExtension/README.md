# Sofa Theater browser helper 0.1.25

This helper contains no chat, account, analytics, or visible toolbar UI. It only
applies Sofa's reversible Theater layout to Netflix and YouTube. While Theater
is active, drag the boundary between the video and its black call column to
resize the video. A system-style grab indicator appears in the black call area
when the pointer reaches the draggable boundary.

Sofa includes the same helper internally, so Safari works without a separate
installation when JavaScript from Apple Events is enabled.

For local Chrome development:

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Choose **Load unpacked** and select this `BrowserExtension` folder.

The extension and Sofa communicate through a closed DOM command bridge; the
extension never receives arbitrary JavaScript from the app.
