"""
External Camera HTTP Stream Server
Run this script on a computer with a camera to stream it via HTTP
Other computers can access the stream using the URL shown when starting

Usage:
    python external_camera_server.py [--port PORT] [--camera-index INDEX]

Example:
    python external_camera_server.py --port 8080 --camera-index 0
"""

import argparse
import cv2
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread
import socket

class StreamingHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/video':
            self.send_response(200)
            self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
            self.end_headers()
            
            try:
                while True:
                    ret, frame = self.server.camera.read()
                    if not ret:
                        break
                    
                    # Resize frame for better performance
                    frame = cv2.resize(frame, (640, 480))
                    
                    # Encode frame as JPEG
                    _, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
                    frame_bytes = buffer.tobytes()
                    
                    # Send frame
                    self.wfile.write(b'--frame\r\n')
                    self.send_header('Content-Type', 'image/jpeg')
                    self.send_header('Content-Length', len(frame_bytes))
                    self.end_headers()
                    self.wfile.write(frame_bytes)
                    self.wfile.write(b'\r\n')
                    
            except Exception as e:
                print(f"Streaming error: {e}")
        else:
            self.send_response(404)
            self.end_headers()

class StreamingServer(HTTPServer):
    def __init__(self, server_address, RequestHandlerClass, camera):
        super().__init__(server_address, RequestHandlerClass)
        self.camera = camera

def get_local_ip():
    """Get the local IP address"""
    try:
        # Connect to a remote address to get local IP
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

def main():
    parser = argparse.ArgumentParser(description='HTTP Camera Stream Server')
    parser.add_argument('--port', type=int, default=8080, help='Port to run the server on (default: 8080)')
    parser.add_argument('--camera-index', type=int, default=0, help='Camera index (default: 0)')
    args = parser.parse_args()
    
    # Open camera
    print(f"Opening camera {args.camera_index}...")
    camera = cv2.VideoCapture(args.camera_index)
    
    if not camera.isOpened():
        print(f"❌ Error: Could not open camera {args.camera_index}")
        print("Please check:")
        print("  1. Camera is connected")
        print("  2. Camera is not being used by another application")
        print("  3. Try a different camera index (0, 1, 2, etc.)")
        return
    
    # Set camera properties
    camera.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    camera.set(cv2.CAP_PROP_FPS, 30)
    
    print(f"✅ Camera opened successfully")
    print(f"   Resolution: {int(camera.get(cv2.CAP_PROP_FRAME_WIDTH))}x{int(camera.get(cv2.CAP_PROP_FRAME_HEIGHT))}")
    print(f"   FPS: {camera.get(cv2.CAP_PROP_FPS)}")
    
    # Get local IP
    local_ip = get_local_ip()
    
    # Create server
    server = StreamingServer(('0.0.0.0', args.port), StreamingHandler, camera)
    
    print("\n" + "="*60)
    print("🌐 Camera Stream Server Started!")
    print("="*60)
    print(f"📹 Camera Index: {args.camera_index}")
    print(f"🌍 Local URL: http://localhost:{args.port}/video")
    print(f"🌐 Network URL: http://{local_ip}:{args.port}/video")
    print("\n💡 To use this camera from another computer:")
    print(f"   Enter this URL in CrowdSense Camera Setup:")
    print(f"   http://{local_ip}:{args.port}/video")
    print("\n⚠️  Make sure:")
    print("   - Both computers are on the same network")
    print("   - Firewall allows connections on port", args.port)
    print("="*60)
    print("\nPress Ctrl+C to stop the server\n")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n\nStopping server...")
    finally:
        camera.release()
        server.server_close()
        print("✅ Server stopped. Camera released.")

if __name__ == '__main__':
    main()

