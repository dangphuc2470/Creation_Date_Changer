using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Drawing;
using System.Drawing.Imaging;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using ExifLib;
using GMap.NET.WindowsForms;
using static System.Windows.Forms.DataFormats;
using static System.Windows.Forms.VisualStyles.VisualStyleElement.Button;
using System.Drawing;
using ExifLib;
using System.Text.Json;
using GMap.NET;
using System.ComponentModel;
using GMap.NET.WindowsForms.Markers;
using System.Drawing.Drawing2D;
using System.Collections.Concurrent;
using static System.Windows.Forms.VisualStyles.VisualStyleElement.TrayNotify;
using static System.Windows.Forms.VisualStyles.VisualStyleElement;
namespace ExifDataModifier
{
    public partial class Form1 : Form
    {
        private List<string> filePaths = new List<string>();
        private List<string> filePathsToDisplayImage = new List<string>();

        private List<DateTime> filePathsDate = new List<DateTime>();
        private List<string> newFileNames = new List<string>();
        private List<MyLocation> imageOnMapList = new List<MyLocation>();
        private Dictionary<string, List<string>> fileGroups = new Dictionary<string, List<string>>();
        private bool isShowNotificationFirstTime = false;
        private volatile bool stopRequested = false;
        private int mapType = 0;
        private PointLatLng defaultLocation = new PointLatLng(40.73061, -73.935242); // New York City
        private MapConfig mapConfig;

        string[] supportedFormats = {
    ".jpg", ".jpeg", ".png", ".gif",  // Common image formats
    ".bmp", ".tiff",                 // Less common image formats
    ".webp", ".heic",                 // Modern image formats
    ".raw",                           // RAW image format
    ".psd",                           // Photoshop Document format
    ".ai",                           // Adobe Illustrator Artwork format
    ".svg",                           // Scalable Vector Graphics format
    ".cr2",
    ".nef",
    ".arw",
    ".orf",
    ".pef",
    ".dng",


    ".mp4", ".mov", ".avi",           // Common video container formats
    ".mkv", ".wmv", ".flv",            // Less common video container formats
    ".webm", ".avchd",                 // Web-friendly and AVCHD video formats
    ".mpeg2",                         // MPEG-2 video format
    ".vp9",                           // VP9 video codec
    ".h263",                          // H.263 video codec
    ".prores",                         // Apple Professional Res video codec
    ".tga",                           // Truevision Graphics Adapter format (legacy)
    ".flic",                          // Flic Animation format (legacy)

};
        string[] supportedImageFormats =
        {
    ".jpg", ".jpeg", ".png", ".gif",  // Common image formats
    ".bmp", ".tiff",                 // Less common image formats
    ".webp", ".heic",                 // Modern image formats
    ".raw",                           // RAW image format
    ".psd",                           // Photoshop Document format
    ".ai",                           // Adobe Illustrator Artwork format
    ".svg",                           // Scalable Vector Graphics format
    ".cr2",
    ".nef",
    ".arw",
    ".orf",
    ".pef",
    ".dng"
        };

        // All the extensions of file can add GPS to metadata
        string[] supportedGeoTagFormats =
        {
    ".jpg", ".jpeg",
    ".tiff",
    ".webp", ".heic",
        };
        private BackgroundWorker backgroundWorkerGeotag;
        private BackgroundWorker backgroundWorkerLoadImage;

        private ProgressForm progressFormGeoTag;
        private ProgressForm progressFormLoadImage;


        public Form1()
        {
            InitializeComponent();
            AllowDrop = true;
            gMapControl1.MapProvider = GMap.NET.MapProviders.GoogleMapProvider.Instance;
            GMap.NET.GMaps.Instance.Mode = GMap.NET.AccessMode.ServerOnly;

            string jsonFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "location.json");
            if (File.Exists(jsonFilePath))
            {
                string json = File.ReadAllText(jsonFilePath);
                mapConfig = JsonSerializer.Deserialize<MapConfig>(json);
                gMapControl1.Position = mapConfig.Center;
                int mapType = mapConfig.MapType;

                gMapControl1.MapProvider = mapType switch
                {
                    0 => GMap.NET.MapProviders.GoogleMapProvider.Instance,
                    1 => GMap.NET.MapProviders.GoogleHybridMapProvider.Instance,
                    2 => GMap.NET.MapProviders.BingMapProvider.Instance,
                    3 => GMap.NET.MapProviders.BingHybridMapProvider.Instance,
                    _ => GMap.NET.MapProviders.GoogleMapProvider.Instance,
                };
            }
            else
                gMapControl1.Position = defaultLocation; // Example: New York City
                                                         // Enable dragging the map:
            gMapControl1.CanDragMap = true;
            gMapControl1.DragButton = MouseButtons.Left; // Use the left mouse button for dragging

            // Enable zooming:
            gMapControl1.MinZoom = 1;  // Minimum zoom level
            gMapControl1.MaxZoom = 20; // Maximum zoom level
            gMapControl1.Zoom = 9;     // Initial zoom level
            gMapControl1.IgnoreMarkerOnMouseWheel = true; // Zoom without centering on markers

            // Optional: Enable mouse wheel zoom without holding down Ctrl
            gMapControl1.MouseWheelZoomType = GMap.NET.MouseWheelZoomType.MousePositionAndCenter;

            // Optional: Disable the red cross when the map is dragged beyond its boundaries
            gMapControl1.ShowTileGridLines = false;
            Init(gMapControl1);
            InitializeBackgroundWorker();



        }

        internal void Init(GMapControl gMapControl)
        {
            var c = gMapControl;
            c.MouseWheel += GMap_MouseWheel;
            c.MouseWheelZoomEnabled = false;

        }

        private void CreateMarker(GMapControl mapControl, double lat, double lng, string toolTipText, string customMarkerPath)
        {
            PointLatLng point = new PointLatLng(lat, lng);

            // Load the custom marker image
            Bitmap customMarkerImage = new Bitmap(customMarkerPath);
            customMarkerImage = CorrectBitmapImageOrientation(customMarkerImage);
            Bitmap resizedImage = ResizeBitmapImageToSquare(customMarkerImage, 50);

            // Create a circular path
            GraphicsPath path = new GraphicsPath();
            path.AddEllipse(0, 0, 50, 50);

            // Make the outside pixels transparent
            for (int y = 0; y < resizedImage.Height; y++)
            {
                for (int x = 0; x < resizedImage.Width; x++)
                {
                    if (!path.IsVisible(x, y))
                    {
                        resizedImage.SetPixel(x, y, Color.Transparent);
                    }
                }
            }

            // Draw a circle around the resized image
            using (Graphics g = Graphics.FromImage(resizedImage))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias; // Enable antialiasing
                Pen pen = new Pen(Color.White, 2); // You can change the color and width of the circle
                g.DrawEllipse(pen, 0, 0, 49, 49);
            }

            // Create the marker with the modified image
            GMarkerGoogle marker = new GMarkerGoogle(point, resizedImage);
            marker.ToolTipText = toolTipText;
            marker.ToolTipMode = MarkerTooltipMode.OnMouseOver;

            // Create and add the overlay
            GMapOverlay overlay = new GMapOverlay(customMarkerPath);
            overlay.Markers.Add(marker);
            mapControl.Overlays.Add(overlay);
        }

        private void GMap_MouseWheel(object sender, MouseEventArgs e)
        {
            if (e.Delta < 0) gMapControl1.Zoom--;
            else gMapControl1.Zoom++;
            // Note: No need to set e.Handled = true; as MouseEventArgs does not contain a Handled property
        }

        private void Form1_DragEnter(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop))
                e.Effect = DragDropEffects.Copy;
            else
                e.Effect = DragDropEffects.None;
        }

        private void Form1_DragDrop(object sender, DragEventArgs e)
        {
            //filePaths.Clear();
            //listBoxFiles.Items.Clear();
            stopRequested = false;
            string[] files = (string[])e.Data.GetData(DataFormats.FileDrop);
            filePaths.AddRange(files);
            filePathsToDisplayImage.AddRange(files);
            DisplayFilePaths();
        }

        private void DisplayFilePaths()
        {
            listBoxFiles.Items.Clear();
            listBoxName.Items.Clear();
            lbNameFromDate.Items.Clear();
            lbNameOriginal.Items.Clear();
            lvImageLocation.Items.Clear();
            imageOnMapList.Clear();
            foreach (string filePath in filePaths)
            {
                listBoxFiles.Items.Add(filePath);
                listBoxName.Items.Add(Path.GetFileName(filePath));
                lbNameOriginal.Items.Add(Path.GetFileName(filePath));
            }

            if (cbLoadImage.Checked)
                LoadImagesIntoListView(filePaths);
            else
            {
                bool isNotSupportedNotification = false;
                foreach (string filePath in filePaths)
                {
                    if (CheckSupported(filePath, supportedGeoTagFormats))
                    {
                        lvImageLocation.Items.Add(Path.GetFileName(filePath));
                        //StartBackgroundWorkLoadImage(filePath)
                    }
                    else
                    {
                        lvImageLocation.Items.Add("(Not supported) " + Path.GetFileName(filePath));
                        isNotSupportedNotification = true;
                    }
                }

                // Only show message one time
                if (isNotSupportedNotification && tabControl1.SelectedTab == tpLocation)
                    MessageBox.Show("Some files are not supported for geotagging and will not be processed", "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);

                AddMarker();
            }


        }



        private void ScanAndGroupFiles(List<string> files)
        {
            fileGroups.Clear();
            cbFileGroup.Items.Clear();
            foreach (string file in files)
            {
                string fileName = Path.GetFileNameWithoutExtension(file);
                string modifiedName = "";

                for (int i = 0; i < fileName.Count(); i++)
                {
                    if (Char.IsDigit(fileName[i]))
                        modifiedName += "*";
                    else
                        modifiedName += fileName[i];
                }

                modifiedName = RemoveSuffix(modifiedName, nmIgnore.Value);
                modifiedName = RemoveFromLast(modifiedName, '*', 1);

                if (!fileGroups.ContainsKey(modifiedName))
                    fileGroups[modifiedName] = new List<string>();

                fileGroups[modifiedName].Add(file);
            }

            // Populate the ComboBox with the first file of each group
            foreach (var group in fileGroups)
            {
                cbFileGroup.Items.Add(Path.GetFileName(group.Value.First()));
            }
            try
            {
                cbFileGroup.SelectedIndex = 0;
            }
            catch
            {
                MessageBox.Show("No image or video found!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }



        private void buttonSetTime_Click(object sender, EventArgs e)
        {
            if (filePaths.Count != filePathsDate.Count)
            {
                MessageBox.Show("Please check the format!");
                return;
            }
            for (int i = 0; i < filePaths.Count; i++)
            {
                DateTime newDateTime = filePathsDate[i];
                File.SetCreationTime(filePaths[i], newDateTime);
                File.SetLastWriteTime(filePaths[i], newDateTime);
            }
            MessageBox.Show("Set time successfully!", "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private void buttonClear_Click(object sender, EventArgs e)
        {
            stopRequested = true;
            filePaths.Clear();
            filePathsDate.Clear();
            filePathsToDisplayImage.Clear();
            listBoxFiles.Items.Clear();
            listBoxName.Items.Clear();
            listBoxExtractedDate.Items.Clear();
            lbNameFromDate.Items.Clear();
            lbNameOriginal.Items.Clear();
            lvImageLocation.Items.Clear();
            imageOnMapList.Clear();
        }

        private void btExtract_Click(object sender, EventArgs e)
        {
            filePathsDate.Clear();
            if (listBoxFiles.Items.Count == 0)
            {
                MessageBox.Show("Nothing to apply", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            listBoxExtractedDate.Items.Clear();
            Exception exception = null;
            foreach (string fileName in listBoxName.Items)
            {
                try
                {
                    string inputFormat = tbRegex.Text;
                    // Lấy vị trí và số lượng cho năm
                    int firstYearIndex = inputFormat.IndexOf("y");
                    int countYear = inputFormat.LastIndexOf("y") - firstYearIndex + 1;

                    // Lấy vị trí và số lượng cho tháng
                    int firstMonthIndex = inputFormat.IndexOf("M");
                    int countMonth = inputFormat.LastIndexOf("M") - firstMonthIndex + 1;

                    // Lấy vị trí và số lượng cho ngày
                    int firstDayIndex = inputFormat.IndexOf("d");
                    int countDay = inputFormat.LastIndexOf("d") - firstDayIndex + 1;

                    // Lấy vị trí và số lượng cho giờ
                    int firstHourIndex = inputFormat.IndexOf("H");
                    int countHour = inputFormat.LastIndexOf("H") - firstHourIndex + 1;

                    // Lấy vị trí và số lượng cho phút
                    int firstMinuteIndex = inputFormat.IndexOf("m");
                    int countMinute = inputFormat.LastIndexOf("m") - firstMinuteIndex + 1;

                    // Lấy vị trí và số lượng cho giây
                    int firstSecondIndex = inputFormat.IndexOf("s");
                    int countSecond = inputFormat.LastIndexOf("s") - firstSecondIndex + 1;
                    // Chuyển đổi chuỗi sang DateTime
                    string dateTimeStrFormatted = fileName.Substring(firstYearIndex, countYear) + fileName.Substring(firstMonthIndex, countMonth) + fileName.Substring(firstDayIndex, countDay) + "-" + fileName.Substring(firstHourIndex, countHour) + fileName.Substring(firstMinuteIndex, countMinute) + fileName.Substring(firstSecondIndex, countSecond);
                    DateTime dateTime = DateTime.ParseExact(dateTimeStrFormatted, tbDateTimeFormat.Text, null);
                    filePathsDate.Add(dateTime);
                    listBoxExtractedDate.Items.Add(dateTime.ToString(tbDateTimeFormat.Text));
                }
                catch (Exception ex)
                {
                    exception = ex;
                    listBoxExtractedDate.Items.Add("Error");
                }

            }

            if (exception != null)
            {
                MessageBox.Show(exception.Message + '\n' + "Check your format!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void cbShowFullPath_CheckedChanged(object sender, EventArgs e)
        {
            if (cbShowFullPath.Checked)
            {
                listBoxFiles.Visible = true;
                listBoxName.Visible = false;
            }
            else
            {
                listBoxFiles.Visible = false;
                listBoxName.Visible = true;
            }
        }

        private void listBoxName_SizeChanged(object sender, EventArgs e)
        {
            listBoxFiles.Size = new Size(listBoxName.Width, listBoxName.Height);
        }

        private void btChooseFolder_Click(object sender, EventArgs e)
        {
            using (FolderBrowserDialog folderBrowserDialog = new FolderBrowserDialog())
            {
                if (folderBrowserDialog.ShowDialog() == DialogResult.OK)
                {
                    filePaths.Clear();
                    // Use SearchOption.AllDirectories to include all subdirectories
                    string[] files = Directory.GetFiles(folderBrowserDialog.SelectedPath, "*.*", SearchOption.AllDirectories);
                    tbPath.Text = folderBrowserDialog.SelectedPath;
                    foreach (string file in files)
                    {
                        // Make sure it only add the Image and Video
                        if (CheckSupported(file, supportedFormats))
                            filePaths.Add(file);
                    }
                    ScanAndGroupFiles(filePaths);
                }
            }
        }

        private void btView_Click(object sender, EventArgs e)
        {
            buttonClear_Click(null, null);

            if (cbFileGroup.SelectedItem != null)
            {
                string groupName = cbFileGroup.SelectedItem.ToString(); // Use selected group name
                string modifiedName = "";

                for (int i = 0; i < groupName.Count(); i++)
                {
                    if (Char.IsDigit(groupName[i]))
                        modifiedName += "*";
                    else
                        modifiedName += groupName[i];
                }

                // Remove extension
                modifiedName = RemoveFromLast(modifiedName, '.', 0);
                // Remove suffix
                modifiedName = RemoveSuffix(modifiedName, nmIgnore.Value);

                // Remove package name of screenshot. Eg: Screenshot_2023-08-17-20-12-32-990_com.tencent.ig
                modifiedName = RemoveFromLast(modifiedName, '*', 1);
                filePaths.Clear();
                foreach (string file in fileGroups[modifiedName])
                {
                    filePaths.Add(file);
                }
                DisplayFilePaths();
            }

        }

        private string RemoveFromLast(string name, char charater, int offset)
        {
            int lastCharaterIndex = name.LastIndexOf(charater);
            if (lastCharaterIndex != -1)
                return name.Substring(0, lastCharaterIndex + offset);
            return name;
        }

        private void btAssign_Click(object sender, EventArgs e)
        {
            string groupName = cbFileGroup.SelectedItem.ToString(); // Use selected group name
            string modifiedName = "";

            int lastDigitIndex = 0;
            for (int i = 0; i < groupName.Count(); i++)
            {
                if (!Char.IsDigit(groupName[i]))
                    modifiedName += "*";
                else
                {
                    modifiedName += groupName[i];
                    lastDigitIndex = i;
                }
            }

            tbRegex.Text = modifiedName.Substring(0, lastDigitIndex + 1);
            if (!isShowNotificationFirstTime)
            {
                MessageBox.Show("Assigned, Please update the number in the filename textbox to match the year, month, day,...", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
                isShowNotificationFirstTime = true;
            }
        }

        private void Form1_ResizeEnd(object sender, EventArgs e)
        {
            // Check the cbShowFullPath two time to make sure it update from the size of ListBox Name (Because it does not placed in tableLayoutPanel2 so it's size does not change automatically)
            cbShowFullPath.Checked = !cbShowFullPath.Checked;
            cbShowFullPath.Checked = !cbShowFullPath.Checked;
        }

        string RemoveSuffix(string name, decimal numberOfLetterToRemove)
        {
            int length = name.Length;
            string modifiedName = name;
            if (length > numberOfLetterToRemove)
                modifiedName = name.Substring(0, (int)(length - numberOfLetterToRemove));
            return modifiedName;
        }

        private void btChangeName_Click(object sender, EventArgs e)
        {
            try
            {
                foreach (string newFileName in newFileNames)
                {
                    if (newFileName == "Error")
                    {
                        DialogResult result = MessageBox.Show("Some file name are not correct, do you want to continue?", "Error", MessageBoxButtons.OKCancel, MessageBoxIcon.Error);
                        if (result == DialogResult.Cancel)
                            return;
                        else
                            break;
                    }
                }

                if (filePaths.Count != newFileNames.Count)
                {
                    MessageBox.Show("Please check the format!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
                for (int i = 0; i < filePaths.Count; i++)
                {
                    string newFileNameWithoutExtension = newFileNames[i];
                    if (newFileNameWithoutExtension == "Error")
                        continue;
                    // Extract the directory, original file name without extension, and extension
                    string directory = Path.GetDirectoryName(filePaths[i]);
                    string originalExtension = Path.GetExtension(filePaths[i]);

                    // Combine the directory, new file name, and original extension
                    string newFilePath = Path.Combine(directory, newFileNameWithoutExtension + originalExtension);

                    File.Move(filePaths[i], newFilePath);
                }

                MessageBox.Show("Success!", "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message);

            }
        }

        private void tabControl1_Deselected(object sender, TabControlEventArgs e)
        {
            buttonClear_Click(null, null);
        }

        private void rbFromModified_Click(object sender, EventArgs e)
        {
            rbFromCreation.Checked = !rbFromModified.Checked;
        }

        private void btFileApply_Click(object sender, EventArgs e)
        {
            newFileNames.Clear();
            lbNameFromDate.Items.Clear();
            string nameFormat = tbFileNameFormat.Text;
            int startIndex = nameFormat.IndexOf("<") + 1;
            int endIndex = nameFormat.IndexOf(">");
            int length = endIndex - startIndex;

            string prefix = nameFormat.Substring(0, startIndex - 1);
            string suffix = nameFormat.Substring(endIndex + 1, nameFormat.Length - endIndex - 1);

            int startSequenceIndex = nameFormat.IndexOf("[");
            int endSequenceIndex = nameFormat.IndexOf("]");
            int lengthSequence = endSequenceIndex - startSequenceIndex - 1;

            nameFormat = nameFormat.Substring(startIndex, length);

            for (int i = 0; i < filePaths.Count; i++)
            {
                try
                {
                    FileInfo fileInfo = new FileInfo(filePaths[i]);
                    DateTime creationTime = fileInfo.CreationTime; // Ngày tạo file
                    DateTime lastModifiedTime = fileInfo.LastWriteTime; // Ngày chỉnh sửa cuối cùng

                    string newName;
                    if (rbFromModified.Checked)
                        newName = prefix + lastModifiedTime.ToString(nameFormat) + suffix;
                    else
                        newName = prefix + creationTime.ToString(nameFormat) + suffix;

                    if (lengthSequence > 0)
                    {
                        // Change position after remove the "<>"
                        int newStartSequenceIndex = startSequenceIndex - 2;
                        int newEndSequenceIndex = endSequenceIndex - 2;
                        string newPrefix = newName.Substring(0, newStartSequenceIndex);
                        string newSuffix = newName.Substring(newEndSequenceIndex + 1, newName.Length - newEndSequenceIndex - 1);
                        newPrefix += i.ToString($"D{lengthSequence}");
                        newName = newPrefix + newSuffix;
                    }
                    newFileNames.Add(newName);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    newFileNames.Add("Error");
                }

            }

            for (int i = 0; i < newFileNames.Count; i++)
            {
                lbNameFromDate.Items.Add(newFileNames[i] + Path.GetExtension(filePaths[i]));
            }


        }

        private void LoadImagesIntoListView(List<string> imagePaths)
        {
            Parallel.ForEach(imagePaths, (path, state) =>
            {
                if (stopRequested)
                {
                    state.Stop(); // Yêu cầu dừng vòng lặp song song
                    return;
                }
                try
                {
                    // If not image, load white image
                    if (!CheckSupported(path, supportedImageFormats))
                    {
                        this.Invoke((MethodInvoker)delegate
                        {
                            int imageIndex = imageList1.Images.Count;
                            imageList1.Images.Add(new Bitmap(100, 100));
                            ListViewItem item = new ListViewItem(Path.GetFileNameWithoutExtension(path))
                            {
                                ImageIndex = imageIndex
                            };
                            lvImageLocation.Items.Add(item);
                        });
                        return;
                    }

                    Image originalImage = Image.FromFile(path);
                    Image resizedImage = ResizeImageToSquare(originalImage);

                    // Marshal the UI update back to the UI thread
                    this.Invoke((MethodInvoker)delegate
                    {
                        int imageIndex = imageList1.Images.Count;
                        //imageList1.Images.Add(resizedImage);

                        // Extract a file name or any other text you want to display next to the image
                        string fileName = Path.GetFileNameWithoutExtension(path);
                        // Create a ListViewItem with text and set its ImageIndex
                        ListViewItem item = new ListViewItem(fileName)
                        {
                            ImageIndex = imageIndex
                        };
                        lvImageLocation.Items.Add(item); // Add the item to the ListView
                    });
                }
                catch (Exception ex)
                {
                    // Handle exceptions (e.g., file not found, invalid image format)
                    // Marshal the exception handling to the UI thread if you need to interact with the UI, e.g., showing a MessageBox
                    this.Invoke((MethodInvoker)delegate
                    {
                        MessageBox.Show($"Error loading image: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    });
                }
            });
            this.Invoke((MethodInvoker)delegate
            {
                lvImageLocation.EndUpdate(); // Ends the update process and repaints the ListView if necessary.
            });
        }

        private bool CheckSupported(string path, string[] supportedFormats)
        {
            return supportedFormats.Contains(Path.GetExtension(path).ToLower());
        }

        private Image ResizeImageToSquare(Image image)
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

        private Image CorrectImageOrientation(Image img)
        {
            if (img.PropertyIdList.Contains(0x0112)) // Check if the image has orientation metadata
            {
                int orientation = (int)img.GetPropertyItem(0x0112).Value[0];
                switch (orientation)
                {
                    case 2:
                        img.RotateFlip(RotateFlipType.RotateNoneFlipX); // Horizontal flip
                        break;
                    case 3:
                        img.RotateFlip(RotateFlipType.Rotate180FlipNone); // 180° rotation
                        break;
                    case 4:
                        img.RotateFlip(RotateFlipType.RotateNoneFlipY); // Vertical flip
                        break;
                    case 5:
                        img.RotateFlip(RotateFlipType.Rotate90FlipX);
                        break;
                    case 6:
                        img.RotateFlip(RotateFlipType.Rotate90FlipNone); // 90° rotation
                        break;
                    case 7:
                        img.RotateFlip(RotateFlipType.Rotate270FlipX);
                        break;
                    case 8:
                        img.RotateFlip(RotateFlipType.Rotate270FlipNone); // 270° rotation
                        break;
                }
                // Remove the orientation property to prevent further adjustments
                img.RemovePropertyItem(0x0112);
            }
            return img;
        }

        private void panel6_SizeChanged(object sender, EventArgs e)
        {

        }

        private void btLocationApply_Click(object sender, EventArgs e)
        {
            if (btLocationApply.Text == "Apply")
                StartProcessing();
            else
                ClearMarker();
        }



        private string ConvertPointLatLngToString(PointLatLng center)
        {
            return $"{center.Lat.ToString("F6")}, {center.Lng.ToString("F6")}";
        }

        private void gMapControl1_MouseUp(object sender, MouseEventArgs e)
        {
            GMap.NET.PointLatLng center = gMapControl1.Position;
            String latlng = ConvertPointLatLngToString(center);

            if (tbLatLgn.Text != latlng)
                tbLatLgn.Text = latlng;
        }

        private void gMapControl1_MouseHover(object sender, EventArgs e)
        {
            GMap.NET.PointLatLng center = gMapControl1.Position;
            String latlng = ConvertPointLatLngToString(center);


            if (tbLatLgn.Text != latlng)
                tbLatLgn.Text = latlng;
        }

        private void tbLatLgn_TextChanged(object sender, EventArgs e)
        {
            GMap.NET.PointLatLng center = gMapControl1.Position;
            String latlngC = ConvertPointLatLngToString(center);


            if (tbLatLgn.Text != latlngC)
            {
                // Move to the location
                string[] latlng = tbLatLgn.Text.Split(',');
                if (latlng.Length == 2)
                {
                    try
                    {
                        double lat = double.Parse(latlng[0]);
                        double lng = double.Parse(latlng[1]);
                        gMapControl1.Position = new GMap.NET.PointLatLng(lat, lng);
                    }
                    catch (Exception ex)
                    { }
                }

            }
        }

        private void ptbSatelite_Click(object sender, EventArgs e)
        {
            // Change the map provider sequenccly from GoogleMapProvider, GoogleHybridMapProvider, BingMapProvider, BingHybridMapProvider
            mapType++;
            if (mapType > 3)
                mapType = 0;

            gMapControl1.MapProvider = mapType switch
            {
                0 => GMap.NET.MapProviders.GoogleMapProvider.Instance,
                1 => GMap.NET.MapProviders.GoogleHybridMapProvider.Instance,
                2 => GMap.NET.MapProviders.BingMapProvider.Instance,
                3 => GMap.NET.MapProviders.BingHybridMapProvider.Instance,
                _ => GMap.NET.MapProviders.GoogleMapProvider.Instance,
            };

            mapConfig.MapType = mapType;
            string json = JsonSerializer.Serialize(mapConfig);
            string jsonFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "location.json");
            File.WriteAllText(jsonFilePath, json);


        }

        private void cbLoadImage_CheckedChanged(object sender, EventArgs e)
        {
            DisplayFilePaths();
        }

        private void InitializeBackgroundWorker()
        {
            backgroundWorkerGeotag = new BackgroundWorker();
            backgroundWorkerGeotag.WorkerReportsProgress = true;
            backgroundWorkerGeotag.DoWork += BackgroundWorkerGeotag_DoWork;
            backgroundWorkerGeotag.ProgressChanged += BackgroundWorkerGeotag_ProgressChanged;
            backgroundWorkerGeotag.RunWorkerCompleted += BackgroundWorkerGeotag_RunWorkerCompleted;

            backgroundWorkerLoadImage = new BackgroundWorker();
            backgroundWorkerLoadImage.WorkerReportsProgress = true;
            backgroundWorkerLoadImage.DoWork += backgroundWorkerLoadImage_DoWork;
            backgroundWorkerLoadImage.RunWorkerCompleted
           += backgroundWorkerLoadImage_RunWorkerCompleted;
            backgroundWorkerLoadImage.ProgressChanged += backgroundWorkerLoadImage_ProgressChanged;
        }

        private void StartProcessing()
        {
            progressFormGeoTag = new ProgressForm();
            progressFormGeoTag.Show();

            backgroundWorkerGeotag.RunWorkerAsync();
        }

        private void BackgroundWorkerGeotag_DoWork(object sender, DoWorkEventArgs e)
        {
            GMap.NET.PointLatLng center = gMapControl1.Position;
            String latlng = ConvertPointLatLngToString(center);

            mapConfig.Center = center;
            mapConfig.MapType = mapType;
            // Save location to json file for later session
            string json = JsonSerializer.Serialize(mapConfig);
            string jsonFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "location.json");
            File.WriteAllText(jsonFilePath, json);

            int totalFiles = filePaths.Count;
            for (int i = 0; i < totalFiles; i++)
            {
                string path = filePaths[i];
                double latitude = center.Lat;
                double longitude = center.Lng;

                if (!CheckSupported(path, supportedGeoTagFormats))
                    continue;

                using (Image originalImage = Image.FromFile(path))
                {
                    using (Image geotaggedImage = Function.Geotag(originalImage, latitude, longitude))
                    {
                        string directory = Path.GetDirectoryName(path);
                        string newDirectory = directory + "_Geotagged";

                        if (!Directory.Exists(newDirectory))
                        {
                            Directory.CreateDirectory(newDirectory);
                        }

                        string newFileName = Path.Combine(newDirectory, Path.GetFileName(path));
                        geotaggedImage.Save(newFileName, originalImage.RawFormat);
                        // Only add the first item to the list
                        if (imageOnMapList.Count == 0)
                        {
                            MyLocation myLocation = new MyLocation(center, newFileName);
                            imageOnMapList.Add(myLocation);
                            AddSingleMarker(myLocation);
                        }
                    }
                }

                int progress = (i + 1) * 100 / totalFiles;
                backgroundWorkerGeotag.ReportProgress(progress, $"Geotaging {i + 1} of {totalFiles} files...");
            }
        }

        private void BackgroundWorkerGeotag_ProgressChanged(object sender, ProgressChangedEventArgs e)
        {
            progressFormGeoTag.UpdateProgress(e.ProgressPercentage, e.UserState.ToString());
        }

        private void BackgroundWorkerGeotag_RunWorkerCompleted(object sender, RunWorkerCompletedEventArgs e)
        {
            progressFormGeoTag.Close();
            AddMarker(false);

            DialogResult dialog = MessageBox.Show($"Geotagged image saved in _Geotagged folder. Clear list?", "Success", MessageBoxButtons.YesNo, MessageBoxIcon.Information);

            if (dialog == DialogResult.Yes)
                buttonClear_Click(null, null);

        }

        private void backgroundWorkerLoadImage_DoWork(object sender, DoWorkEventArgs e)
        {
            int processedFiles = 0;
            int totalFiles = filePathsToDisplayImage.Count;

            foreach (String filePath in filePathsToDisplayImage)
            {
                // If file not have GPS data, skip it
                if (!CheckSupported(filePath, supportedGeoTagFormats))
                    continue;

                using (Image image = Image.FromFile(filePath))
                {
                    PointLatLng gpsData = Function.GetGPS(filePath);
                    if (gpsData.Lat != -1000)
                    {
                        MyLocation location = new MyLocation(gpsData, filePath);
                        imageOnMapList.Add(location);
                    }
                }

                processedFiles++;
                double progress = processedFiles * 1.0 / totalFiles * 100;
                backgroundWorkerLoadImage.ReportProgress((int)progress, $"Loading {processedFiles} of {totalFiles} files...");
            }
            // Clear the list to avoid reloading the same images
            filePathsToDisplayImage.Clear();
            // Remove duplicates
            imageOnMapList = imageOnMapList.GroupBy(x => x.getLatLngString()).Select(x => x.First()).ToList();
            e.Result = imageOnMapList;
        }

        private void backgroundWorkerLoadImage_RunWorkerCompleted(object sender, RunWorkerCompletedEventArgs e)
        {
            if (progressFormLoadImage != null)
                progressFormLoadImage.Close();

            if (e.Error != null)
            {
                // Handle anyerrors during background processing
                MessageBox.Show("Error occurred during processing: " + e.Error.Message);
                return;
            }

            List<MyLocation> imageOnMapList = (List<MyLocation>)e.Result;

            // Add markers and refresh map
            foreach (MyLocation location in imageOnMapList)
            {
                CreateMarker(gMapControl1, location.getLatLng().Lat, location.getLatLng().Lng, location.getLatLngString(), location.getName());
            }
            SimulateMapReload(gMapControl1);

        }

        private void backgroundWorkerLoadImage_ProgressChanged(object sender, ProgressChangedEventArgs e)
        {
            progressFormLoadImage.UpdateProgress(e.ProgressPercentage, e.UserState.ToString());
        }

        private void AddMarker(bool isShowProgress = true)
        {
            if (rbDisplayImage.Checked == true && isShowProgress)
            {
                progressFormLoadImage = new ProgressForm();
                progressFormLoadImage.Show();
                backgroundWorkerLoadImage.RunWorkerAsync();
            }
            else
                Console.WriteLine("Not perform add marker");
        }

        private void AddSingleMarker(MyLocation location)
        {
            CreateMarker(gMapControl1, location.getLatLng().Lat, location.getLatLng().Lng, location.getLatLngString(), location.getName());
            SimulateMapReload(gMapControl1);
        }

        private void ClearMarker()
        {
            gMapControl1.Overlays.Clear();
            imageOnMapList.Clear();
            lvImageLocation.Clear();
            gMapControl1.Refresh();
        }

        private void SimulateMapReload(GMapControl mapControl)
        {
            double zoom = mapControl.Zoom;
            mapControl.Zoom = zoom - 1;
            mapControl.Zoom = zoom;
        }

        private void rbDisplayImage_CheckedChanged(object sender, EventArgs e)
        {
            if (rbDisplayImage.Checked)
            { 
                AddMarker(filePathsToDisplayImage.Count>0);
                btLocationApply.Text = "Clear marker";
            }
            else
            {
                btLocationApply.Text = "Apply";
                buttonClear_Click(null, null);
            }

        }
    }

}
