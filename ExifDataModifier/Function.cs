using System;
using System.Collections.Generic;
using System.Drawing.Imaging;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Diagnostics;
using GMap.NET;
using GMap.NET.WindowsForms;
using System.Text.Json;
using System.Drawing.Drawing2D;

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
    
        public static string RemoveSuffix(string name, decimal numberOfLetterToRemove)
        {
            int length = name.Length;
            string modifiedName = name;
            if (length > numberOfLetterToRemove)
                modifiedName = name.Substring(0, (int)(length - numberOfLetterToRemove));
            return modifiedName;
        }

        public static string RemoveFromLast(string name, char charater, int offset)
        {
            int lastCharaterIndex = name.LastIndexOf(charater);
            if (lastCharaterIndex != -1)
                return name.Substring(0, lastCharaterIndex + offset);
            return name;
        }

        public static bool CheckSupported(string path, string[] supportedFormats)
        {
            return supportedFormats.Contains(Path.GetExtension(path).ToLower());
        }

        public static string ConvertPointLatLngToString(PointLatLng center)
        {
            return $"{center.Lat.ToString("F6")}, {center.Lng.ToString("F6")}";
        }
#region Working with Image
        public static Image ResizeImageToSquare(Image image)
        {
            // Correct orientation
            //image = CorrectImageOrientation(image);

            int size = Math.Min(image.Width, image.Height); // Find the shortest dimension
            int x = (image.Width - size) / 2;
            int y = (image.Height - size) / 2;

            // Create a new Bitmap with the desired size
            Bitmap croppedImage = new Bitmap(size, size);
            using (Graphics g = Graphics.FromImage(croppedImage))
            {
                // Draw the original image, cropped to a square
                g.DrawImage(image, new Rectangle(0, 0, size, size), new Rectangle(x, y, size, size), GraphicsUnit.Pixel);
            }

            return croppedImage;
        }

        public static Bitmap ResizeBitmapImageToSquare(Bitmap originalImage, int size)
        {
            // Determine the dimensions of the square crop
            int cropSize = Math.Min(originalImage.Width, originalImage.Height);

            // Calculate the starting point to crop the image from the center
            int cropX = (originalImage.Width - cropSize) / 2;
            int cropY = (originalImage.Height - cropSize) / 2;

            // Create a new bitmap with the square dimensions
            Bitmap squareImage = new Bitmap(size, size);

            // Draw the cropped portion of the original image onto the new bitmap
            using (Graphics g = Graphics.FromImage(squareImage))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;

                // Draw the cropped image onto the new square bitmap
                g.DrawImage(originalImage, new Rectangle(0, 0, size, size), new Rectangle(cropX, cropY, cropSize, cropSize), GraphicsUnit.Pixel);
            }

            return squareImage;
        }

        public static Bitmap CorrectBitmapImageOrientation(Bitmap originalImage)
        {
            const int ExifOrientationTag = 0x0112; // The EXIF tag for orientation

            // Check if the image has the orientation property
            if (Array.IndexOf(originalImage.PropertyIdList, ExifOrientationTag) < 0)
                return originalImage;

            // Get the orientation property
            var orientationProperty = originalImage.GetPropertyItem(ExifOrientationTag);
            int orientationValue = BitConverter.ToUInt16(orientationProperty.Value, 0);

            // Create a new bitmap to apply transformations
            Bitmap correctedImage = (Bitmap)originalImage.Clone();

            // Apply transformations based on the orientation value
            switch (orientationValue)
            {
                case 1: // Normal (no transformation needed)
                    break;
                case 2: // Flip horizontal
                    correctedImage.RotateFlip(RotateFlipType.RotateNoneFlipX);
                    break;
                case 3: // Rotate 180 degrees
                    correctedImage.RotateFlip(RotateFlipType.Rotate180FlipNone);
                    break;
                case 4: // Flip vertical
                    correctedImage.RotateFlip(RotateFlipType.RotateNoneFlipY);
                    break;
                case 5: // Rotate 90 degrees clockwise and flip horizontal
                    correctedImage.RotateFlip(RotateFlipType.Rotate90FlipX);
                    break;
                case 6: // Rotate 90 degrees clockwise
                    correctedImage.RotateFlip(RotateFlipType.Rotate90FlipNone);
                    break;
                case 7: // Rotate 90 degrees counterclockwise and flip horizontal
                    correctedImage.RotateFlip(RotateFlipType.Rotate270FlipX);
                    break;
                case 8: // Rotate 90 degrees counterclockwise
                    correctedImage.RotateFlip(RotateFlipType.Rotate270FlipNone);
                    break;
                default: // Unknown orientation value, return the original image
                    return originalImage;
            }

            return correctedImage;
        }

        public static void ChangeTextForSecond(Object obj, string text, int seconds)
        {
            //Object can be button or label, textbox, richtextbox, etc
            if (obj is Button)
            {
                string originalText = ((Button)obj).Text;
                ((Button)obj).Text = text;
                Task.Delay(seconds).ContinueWith(t => ((Button)obj).Invoke(new Action(() => ((Button)obj).Text = originalText)));
            }
            // else if (obj is Label)
            // {
            //     Label label = (Label)obj;
            //     string originalText = label.Text;
            //     label.Text = text;
            //     Task.Delay(seconds).ContinueWith(t => label.Text = originalText);
            // }
            // else if (obj is TextBox)
            // {
            //     TextBox textBox = (TextBox)obj;
            //     string originalText = textBox.Text;
            //     textBox.Text = text;
            //     Task.Delay(seconds).ContinueWith(t => textBox.Text = originalText);
            // }
            // else if (obj is RichTextBox)
            // {
            //     RichTextBox richTextBox = (RichTextBox)obj;
            //     string originalText = richTextBox.Text;
            //     richTextBox.Text = text;
            //     Task.Delay(seconds).ContinueWith(t => richTextBox.Text = originalText);
            // }
            else if (obj is Label)
            {
                string originalText = ((Label)obj).Text;
                ((Label)obj).Text = text;
                Task.Delay(seconds).ContinueWith(t => ((Label)obj).Invoke(new Action(() => ((Label)obj).Text = originalText)));
            }
            else if (obj is TextBox)
            {
                string originalText = ((TextBox)obj).Text;
                ((TextBox)obj).Text = text;
                Task.Delay(seconds).ContinueWith(t => ((TextBox)obj).Invoke(new Action(() => ((TextBox)obj).Text = originalText)));
            }
            else if (obj is RichTextBox)
            {
                string originalText = ((RichTextBox)obj).Text;
                ((RichTextBox)obj).Text = text;
                Task.Delay(seconds).ContinueWith(t => ((RichTextBox)obj).Invoke(new Action(() => ((RichTextBox)obj).Text = originalText)));
            }
        }

        public static string[] GetFilesOnly(string path)
    {
        if (!Directory.Exists(path))
        {
            throw new DirectoryNotFoundException($"The directory '{path}' does not exist.");
        }

        return Directory.GetFiles(path);
    }
        
        
#endregion
    }

    public class FormAction
    {
        public static void InitGmap(GMapControl gMapControl, Form1 form)
        {
            gMapControl.MapProvider = GMap.NET.MapProviders.GoogleMapProvider.Instance;
            GMap.NET.GMaps.Instance.Mode = GMap.NET.AccessMode.ServerOnly;

            string jsonFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "location.json");
            if (File.Exists(jsonFilePath))
            {
                string json = File.ReadAllText(jsonFilePath);
                form.mapConfig = JsonSerializer.Deserialize<MapConfig>(json);
                gMapControl.Position = form.mapConfig.Center;
                int mapType = form.mapConfig.MapType;

                gMapControl.MapProvider = mapType switch
                {
                    0 => GMap.NET.MapProviders.GoogleMapProvider.Instance,
                    1 => GMap.NET.MapProviders.GoogleHybridMapProvider.Instance,
                    2 => GMap.NET.MapProviders.BingMapProvider.Instance,
                    3 => GMap.NET.MapProviders.BingHybridMapProvider.Instance,
                    _ => GMap.NET.MapProviders.GoogleMapProvider.Instance,
                };
            }
            else
                gMapControl.Position = form.defaultLocation; // Example: New York City
                                                         // Enable dragging the map:
            gMapControl.CanDragMap = true;
            gMapControl.DragButton = MouseButtons.Left; // Use the left mouse button for dragging

            // Enable zooming:
            gMapControl.MinZoom = 1;  // Minimum zoom level
            gMapControl.MaxZoom = 20; // Maximum zoom level
            gMapControl.Zoom = 9;     // Initial zoom level
            gMapControl.IgnoreMarkerOnMouseWheel = true; // Zoom without centering on markers

            // Optional: Enable mouse wheel zoom without holding down Ctrl
            gMapControl.MouseWheelZoomType = GMap.NET.MouseWheelZoomType.MousePositionAndCenter;

            // Optional: Disable the red cross when the map is dragged beyond its boundaries
            gMapControl.ShowTileGridLines = false;
            var c = gMapControl;
            c.MouseWheel += form.GMap_MouseWheel;
            c.MouseWheelZoomEnabled = false;

        }
    }
}