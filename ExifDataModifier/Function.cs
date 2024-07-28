using System;
using System.Collections.Generic;
using System.Drawing.Imaging;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Diagnostics;
using GMap.NET;

namespace ExifDataModifier
{
    public class Function
    {
        public static Image Geotag(Image original, double lat, double lng)
        {
            // These constants come from the CIPA DC-008 standard for EXIF 2.3
            const short ExifTypeByte = 1;
            const short ExifTypeAscii = 2;
            const short ExifTypeRational = 5;

            const int ExifTagGPSVersionID = 0x0000;
            const int ExifTagGPSLatitudeRef = 0x0001;
            const int ExifTagGPSLatitude = 0x0002;
            const int ExifTagGPSLongitudeRef = 0x0003;
            const int ExifTagGPSLongitude = 0x0004;

            char latHemisphere = 'N';
            if (lat < 0)
            {
                latHemisphere = 'S';
                lat = -lat;
            }
            char lngHemisphere = 'E';
            if (lng < 0)
            {
                lngHemisphere = 'W';
                lng = -lng;
            }

            MemoryStream ms = new MemoryStream();
            original.Save(ms, ImageFormat.Jpeg);
            ms.Seek(0, SeekOrigin.Begin);

            Image img = Image.FromStream(ms);
            AddProperty(img, ExifTagGPSVersionID, ExifTypeByte, new byte[] { 2, 3, 0, 0 });
            AddProperty(img, ExifTagGPSLatitudeRef, ExifTypeAscii, new byte[] { (byte)latHemisphere, 0 });
            AddProperty(img, ExifTagGPSLatitude, ExifTypeRational, ConvertToRationalTriplet(lat));
            AddProperty(img, ExifTagGPSLongitudeRef, ExifTypeAscii, new byte[] { (byte)lngHemisphere, 0 });
            AddProperty(img, ExifTagGPSLongitude, ExifTypeRational, ConvertToRationalTriplet(lng));

            return img;
        }

        public static byte[] ConvertToRationalTriplet(double value)
        {
            int degrees = (int)Math.Floor(value);
            value = (value - degrees) * 60;
            int minutes = (int)Math.Floor(value);
            value = (value - minutes) * 60 * 100;
            int seconds = (int)Math.Round(value);
            byte[] bytes = new byte[3 * 2 * 4]; // Degrees, minutes, and seconds, each with a numerator and a denominator, each composed of 4 bytes
            int i = 0;
            Array.Copy(BitConverter.GetBytes(degrees), 0, bytes, i, 4); i += 4;
            Array.Copy(BitConverter.GetBytes(1), 0, bytes, i, 4); i += 4;
            Array.Copy(BitConverter.GetBytes(minutes), 0, bytes, i, 4); i += 4;
            Array.Copy(BitConverter.GetBytes(1), 0, bytes, i, 4); i += 4;
            Array.Copy(BitConverter.GetBytes(seconds), 0, bytes, i, 4); i += 4;
            Array.Copy(BitConverter.GetBytes(100), 0, bytes, i, 4);
            return bytes;
        }

        public static void AddProperty(Image img, int id, short type, byte[] value)
        {
            PropertyItem pi = img.PropertyItems[0];
            pi.Id = id;
            pi.Type = type;
            pi.Len = value.Length;
            pi.Value = value;
            img.SetPropertyItem(pi);
        }

        public static void GeotagVideo(string videoPath, double latitude, double longitude)
        {
            string outputPath = Path.Combine(Path.GetDirectoryName(videoPath), Path.GetFileNameWithoutExtension(videoPath) + "_Geotagged" + Path.GetExtension(videoPath));

            // FFmpeg command to add geolocation metadata
            string arguments = $"-i \"{videoPath}\" -metadata:s:v:0 location=+{latitude:+00.0000;-00.0000}/{longitude:+00.0000;-00.0000} \"{outputPath}\"";

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = "ffmpeg",
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using (Process process = Process.Start(startInfo))
            {
                process.WaitForExit();

                // Optionally, handle process output or errors
                string output = process.StandardOutput.ReadToEnd();
                string error = process.StandardError.ReadToEnd();
                MessageBox.Show(output);
            }

            // Additional logic to handle the output file, such as setting creation and modification dates, can be added here
        }
        public static PointLatLng GetGPS(string filePath)
        {
            PointLatLng point;
            using (var image = new Bitmap(filePath))
            {
                try
                {
                    PropertyItem latitudeItem = image.GetPropertyItem(2);
                    PropertyItem longitudeItem = image.GetPropertyItem(4);

                    if (latitudeItem != null && longitudeItem != null)
                    {
                        double latDegrees = BitConverter.ToInt32(latitudeItem.Value, 0) / (double)BitConverter.ToInt32(latitudeItem.Value, 4);
                        double latMinutes = BitConverter.ToInt32(latitudeItem.Value, 8) / (double)BitConverter.ToInt32(latitudeItem.Value, 12);
                        double latSeconds = BitConverter.ToInt32(latitudeItem.Value, 16) / (double)BitConverter.ToInt32(latitudeItem.Value, 20);

                        double lonDegrees = BitConverter.ToInt32(longitudeItem.Value, 0) / (double)BitConverter.ToInt32(longitudeItem.Value, 4);
                        double lonMinutes = BitConverter.ToInt32(longitudeItem.Value, 8) / (double)BitConverter.ToInt32(longitudeItem.Value, 12);
                        double lonSeconds = BitConverter.ToInt32(longitudeItem.Value, 16) / (double)BitConverter.ToInt32(longitudeItem.Value, 20);

                        double latitude = latDegrees + latMinutes / 60 + latSeconds / 3600;
                        double longitude = lonDegrees + lonMinutes / 60 + lonSeconds / 3600;
                        point = new PointLatLng(latitude, longitude);
                    }
                    else
                        point = new PointLatLng(-1000, -1000);
                }
                catch {
                    point = new PointLatLng(-1000, -1000);
                }
                
               return point;
            }
        }
    }
}