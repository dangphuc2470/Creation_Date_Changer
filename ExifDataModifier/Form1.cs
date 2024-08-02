using System.Drawing.Imaging;
using GMap.NET.WindowsForms;
using GMap.NET;
using System.ComponentModel;
using GMap.NET.WindowsForms.Markers;
using System.Drawing.Drawing2D;
using System.Text;
using Newtonsoft.Json;
namespace ExifDataModifier
{
    public partial class Form1 : Form
    {
        private List<string> filePaths = new List<string>();
        private List<string> filePathsToDisplayImage = new List<string>();

        private List<DateTime> filePathsDate = new List<DateTime>();
        private List<string> newFileNames = new List<string>();
        private List<int> notSupportedIndex = new List<int>();
        private List<MyLocation> imageOnMapList = new List<MyLocation>();
        private List<MyLocation> savedLocations = new List<MyLocation>();
        private Dictionary<string, List<string>> fileGroups = new Dictionary<string, List<string>>();
        private bool isShowNotificationFirstTime = false;
        private volatile bool stopRequested = false;
        private int mapType = 0;
        public PointLatLng defaultLocation = new PointLatLng(40.73061, -73.935242); // New York City
        public MapConfig mapConfig = new MapConfig();
        bool isScanFolder = false;
        private MessageBoxDefaultButton messageBoxDefaultButtonForFile = MessageBoxDefaultButton.Button1;

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
        private BackgroundWorker backgroundWorkerLoadImageDate;


        private ProgressForm progressFormGeoTag;
        private ProgressForm progressFormLoadImage;
        private ProgressForm progressFormLoadImageDate;


        public Form1()
        {
            InitializeComponent();
            AllowDrop = true;
            FormAction.InitGmap(gMapControl1, this);
            UpdateLatLgnTextBox();

            string jsonFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "saved_locations.json");
            if (File.Exists(jsonFilePath))
            {
                string json = File.ReadAllText(jsonFilePath);
                savedLocations = System.Text.Json.JsonSerializer.Deserialize<List<MyLocation>>(json);
                rtbLocationIndex.Text = "0/" + savedLocations.Count;
                rtbLocationIndex.Tag = savedLocations.Count;
            }

            InitializeBackgroundWorker();
        }



        private void CreateMarker(GMapControl mapControl, double lat, double lng, string toolTipText, string customMarkerPath)
        {
            PointLatLng point = new PointLatLng(lat, lng);

            // Load the custom marker image
            Bitmap customMarkerImage = new Bitmap(customMarkerPath);
            customMarkerImage = Function.CorrectBitmapImageOrientation(customMarkerImage);
            Bitmap resizedImage = Function.ResizeBitmapImageToSquare(customMarkerImage, 50);

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

        public void GMap_MouseWheel(object sender, MouseEventArgs e)
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
            //listBoxFiles.ClearItems();
            cbFileGroup.Items.Clear();
            cbFileGroup.Text = "";
            stopRequested = false;
            string[] files = (string[])e.Data.GetData(DataFormats.FileDrop);
            // Remove folder from the array
            files = files.Where(x => !Directory.Exists(x)).ToArray();
            filePaths.AddRange(files);
            filePathsToDisplayImage.AddRange(files);
            DisplayFilePaths();
        }

        private void DisplayFilePaths()
        {
            lvDateFiles.ClearItems();
            lvDateName.ClearItems(); ;
            lvNameFromDate.ClearItems(); ;
            lvNameOriginal.ClearItems(); ;
            lvImageLocation.ClearItems(); ;
            imageOnMapList.Clear();
            foreach (string filePath in filePaths)
            {
                lvDateFiles.AddItem(filePath);
                lvDateName.AddItem(Path.GetFileName(filePath));
                lvNameOriginal.AddItem(Path.GetFileName(filePath));
            }

            //if (cbLoadImage.Checked)
            //    Function.LoadImagesIntoListView(filePaths);
            //else
            //{
            bool isNotSupportedNotification = false;
            foreach (string filePath in filePaths)
            {
                if (Function.CheckSupported(filePath, supportedGeoTagFormats))
                {
                    lvImageLocation.AddItem(Path.GetFileName(filePath));
                    //StartBackgroundWorkLoadImage(filePath)
                }
                else
                {
                    lvImageLocation.AddItem("(Not supported) " + Path.GetFileName(filePath));
                    isNotSupportedNotification = true;
                }
            }

            // Only show message one time
            if (isNotSupportedNotification && tabControl1.SelectedTab == tpLocation)
                MessageBox.Show("Some files are not supported for geotagging and will not be processed", "Warning", MessageBoxButtons.OK, MessageBoxIcon.Warning);

            StartProcessingAddMarker();
            //}


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

                modifiedName = Function.RemoveSuffix(modifiedName, nmIgnore.Value);
                modifiedName = Function.RemoveFromLast(modifiedName, '*', 1);

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
            if (listBoxExtractedDate.Items.Count == 0)
            {
                MessageBox.Show("Click apply to extract the date first!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            if (filePaths.Count != filePathsDate.Count)
            {
                MessageBox.Show("Check the format or your input file name!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
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
            imageOnMapList.Clear();
            lvDateFiles.ClearItems();
            lvDateName.ClearItems();
            listBoxExtractedDate.ClearItems();
            lvNameFromDate.ClearItems();
            lvNameOriginal.ClearItems();
            lvImageLocation.ClearItems();
            isScanFolder = false;
        }

        private void btExtract_Click(object sender, EventArgs e)
        {
            filePathsDate.Clear();
            if (lvDateFiles.Items.Count == 0)
            {
                MessageBox.Show("Nothing to apply", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            listBoxExtractedDate.ClearItems();
            Exception exception = null;
            foreach (ListViewItem item in lvDateName.Items)
            {
                string fileName = item.SubItems[1].Text;
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
                    listBoxExtractedDate.AddItem(dateTime.ToString(tbDateTimeFormat.Text));
                }
                catch (Exception ex)
                {
                    exception = ex;
                    listBoxExtractedDate.AddItem("Error");
                }

            }

            if (exception != null)
            {
                MessageBox.Show(exception.Message + '\n' + "Check your format or your original file name!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void cbShowFullPath_CheckedChanged(object sender, EventArgs e)
        {
            if (cbShowFullPath.Checked)
            {
                lvDateFiles.Visible = true;
                lvDateName.Visible = false;
            }
            else
            {
                lvDateFiles.Visible = false;
                lvDateName.Visible = true;
            }
        }

        private void listBoxName_SizeChanged(object sender, EventArgs e)
        {
            lvDateFiles.Size = new Size(lvDateName.Width, lvDateName.Height);
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
                        if (Function.CheckSupported(file, supportedFormats))
                            filePaths.Add(file);
                    }
                    ScanAndGroupFiles(filePaths);
                }
            }
        }

        private void btView_Click(object sender, EventArgs e)
        {
            buttonClear_Click(null, null);
            isScanFolder = true;
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
                modifiedName = Function.RemoveFromLast(modifiedName, '.', 0);
                // Remove suffix
                modifiedName = Function.RemoveSuffix(modifiedName, nmIgnore.Value);

                // Remove package name of screenshot. Eg: Screenshot_2023-08-17-20-12-32-990_com.tencent.ig
                modifiedName = Function.RemoveFromLast(modifiedName, '*', 1);
                filePaths.Clear();
                foreach (string file in fileGroups[modifiedName])
                {
                    filePaths.Add(file);
                }
                DisplayFilePaths();
            }

        }


        private void btAssign_Click(object sender, EventArgs e)
        {
            string groupName = "";
            if (cbFileGroup.Items.Count != 0)
            {
                if (cbFileGroup.SelectedItem == null)
                    cbFileGroup.SelectedIndex = 0;
                groupName = cbFileGroup.SelectedItem.ToString();
            }
            else
                groupName = Path.GetFileNameWithoutExtension(filePaths[0]);
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
                MessageBox.Show("Assigned, update the number in the filename textbox to match the year, month, day,...", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
                isShowNotificationFirstTime = true;
            }
        }

        private void Form1_ResizeEnd(object sender, EventArgs e)
        {
            // Check the cbShowFullPath two time to make sure it update from the size of ListBox Name (Because it does not placed in tableLayoutPanel2 so it's size does not change automatically)
            cbShowFullPath.Checked = !cbShowFullPath.Checked;
            cbShowFullPath.Checked = !cbShowFullPath.Checked;
            lvDateFiles.Size = new Size(lvDateName.Width, lvDateName.Height);

            tbLatLgn.Location = new Point(
            358,
            ClientSize.Height - btLocationApply.Height - tbLatLgn.Height - 40);
            ptbSatelite.Location = new Point(358, tbLatLgn.Location.Y - ptbSatelite.Height - 2);

            lvImageLocation.Size = new Size(
                lvImageLocation.Size.Width,
                ClientSize.Height - 150);
            groupBox1.Location = new Point(5, lvImageLocation.Size.Height + 8);
        }


        #region Extract Date and set file name
        private void btFileChangeName_Click(object sender, EventArgs e)
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
                    MessageBox.Show("Check the format!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
                for (int i = 0; i < filePaths.Count; i++)
                {
                    if (notSupportedIndex.Contains(i))
                        continue;

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
                if (ex.Message == "Cannot create a file when that file already exists.")
                    MessageBox.Show("Some file name are duplicate, please check again or consider adding sequence number, eg: yourfilenameformat_[nnnn]", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                else
                    MessageBox.Show(ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);

            }
        }

        private void cbFromDateTaken_CheckedChanged(object sender, EventArgs e)
        {
            // Only show one time
            if (cbFromDateTaken.Checked && cbFromDateTaken.Tag.ToString() == "Uncheck")
            {
                MessageBox.Show("This feature does not support RAW image format and some other type, supported file will have (T) after the name to indicate, the final name will not include it.", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
                cbFromDateTaken.Tag = "Check";
            }
            btFilePreview_Click(null, null);
        }

        private void tabControl1_Deselected(object sender, TabControlEventArgs e)
        {
            //buttonClear_Click(null, null);
        }

        private void rbModifiedAndCreatedDate_Click(object sender, EventArgs e)
        {
            rbFromCreation.Checked = !rbFromModified.Checked;
            btFilePreview_Click(null, null);
        }

        private void btFilePreview_Click(object sender, EventArgs e)
        {
            if (cbFromDateTaken.Checked)
            {
                StartBackgroundWorkLoadImageDate();
            }
            else
            {
                newFileNames.Clear();
                lvNameFromDate.ClearItems();
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

                List<string> newFileNameToInsertToListview = new List<string>();
                for (int i = 0; i < filePaths.Count; i++)
                {
                    FileInfo fileInfo = new FileInfo(filePaths[i]);
                    DateTime creationTime = fileInfo.CreationTime; // Ngày tạo file
                    DateTime lastModifiedTime = fileInfo.LastWriteTime; // Ngày chỉnh sửa cuối cùng
                    string newName;

                    if (rbFromModified.Checked)
                        newName = prefix + lastModifiedTime.ToString(nameFormat) + suffix;
                    else
                        newName = prefix + creationTime.ToString(nameFormat) + suffix;

                    if (lengthSequence > 0 && newName != "Error")
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
                    newFileNameToInsertToListview.Add(newName);
                }

                for (int i = 0; i < newFileNameToInsertToListview.Count; i++)
                {
                    lvNameFromDate.AddItem(newFileNameToInsertToListview[i] + Path.GetExtension(filePaths[i]));
                }
            }


        }

        private void StartBackgroundWorkLoadImageDate()
        {
            progressFormLoadImageDate = new ProgressForm();
            progressFormLoadImageDate.Show();
            backgroundWorkerLoadImageDate.RunWorkerAsync();
        }


        #endregion
        // private void LoadImagesIntoListView(List<string> imagePaths)
        // {
        //     Parallel.ForEach(imagePaths, (path, state) =>
        //     {
        //         if (stopRequested)
        //         {
        //             state.Stop(); // Yêu cầu dừng vòng lặp song song
        //             return;
        //         }
        //         try
        //         {
        //             // If not image, load white image
        //             if (!Function.CheckSupported(path, supportedImageFormats))
        //             {
        //                 this.Invoke((MethodInvoker)delegate
        //                 {
        //                     int imageIndex = imageList1.Images.Count;
        //                     imageList1.Images.Add(new Bitmap(100, 100));
        //                     ListViewItem item = new ListViewItem(Path.GetFileNameWithoutExtension(path))
        //                     {
        //                         ImageIndex = imageIndex
        //                     };
        //                     lvImageLocation.AddItem(item);
        //                 });
        //                 return;
        //             }

        //             Image originalImage = Image.FromFile(path);
        //             Image resizedImage = ResizeImageToSquare(originalImage);

        //             // Marshal the UI update back to the UI thread
        //             this.Invoke((MethodInvoker)delegate
        //             {
        //                 int imageIndex = imageList1.Images.Count;
        //                 //imageList1.Images.Add(resizedImage);

        //                 // Extract a file name or any other text you want to display next to the image
        //                 string fileName = Path.GetFileNameWithoutExtension(path);
        //                 // Create a ListViewItem with text and set its ImageIndex
        //                 ListViewItem item = new ListViewItem(fileName)
        //                 {
        //                     ImageIndex = imageIndex
        //                 };
        //                 lvImageLocation.AddItem(item); // Add the item to the ListView
        //             });
        //         }
        //         catch (Exception ex)
        //         {
        //             // Handle exceptions (e.g., file not found, invalid image format)
        //             // Marshal the exception handling to the UI thread if you need to interact with the UI, e.g., showing a MessageBox
        //             this.Invoke((MethodInvoker)delegate
        //             {
        //                 MessageBox.Show($"Error loading image: {ex.Message}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        //             });
        //         }
        //     });
        //     this.Invoke((MethodInvoker)delegate
        //     {
        //         lvImageLocation.EndUpdate(); // Ends the update process and repaints the ListView if necessary.
        //     });
        // }




        // private Image CorrectImageOrientation(Image img)
        // {
        //     if (img.PropertyIdList.Contains(0x0112)) // Check if the image has orientation metadata
        //     {
        //         int orientation = (int)img.GetPropertyItem(0x0112).Value[0];
        //         switch (orientation)
        //         {
        //             case 2:
        //                 img.RotateFlip(RotateFlipType.RotateNoneFlipX); // Horizontal flip
        //                 break;
        //             case 3:
        //                 img.RotateFlip(RotateFlipType.Rotate180FlipNone); // 180° rotation
        //                 break;
        //             case 4:
        //                 img.RotateFlip(RotateFlipType.RotateNoneFlipY); // Vertical flip
        //                 break;
        //             case 5:
        //                 img.RotateFlip(RotateFlipType.Rotate90FlipX);
        //                 break;
        //             case 6:
        //                 img.RotateFlip(RotateFlipType.Rotate90FlipNone); // 90° rotation
        //                 break;
        //             case 7:
        //                 img.RotateFlip(RotateFlipType.Rotate270FlipX);
        //                 break;
        //             case 8:
        //                 img.RotateFlip(RotateFlipType.Rotate270FlipNone); // 270° rotation
        //                 break;
        //         }
        //         // Remove the orientation property to prevent further adjustments
        //         img.RemovePropertyItem(0x0112);
        //     }
        //     return img;
        // }


        #region Location

        private void btLocationApply_Click(object sender, EventArgs e)
        {
            if (btLocationApply.Text == "Apply")
            {
                if (filePaths.Count != 0)
                    StartProcessingGeotag();
                else
                    MessageBox.Show("No file to process!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            else
                ClearMarker();
        }

        private void gMapControl1_OnMapDrag()
        {
            UpdateLatLgnTextBox();
        }

        private void UpdateLatLgnTextBox()
        {
            GMap.NET.PointLatLng center = gMapControl1.Position;
            String latlng = Function.ConvertPointLatLngToString(center);

            if (tbLatLgn.Text != latlng)
                tbLatLgn.Text = latlng;
        }

        private void tbLatLgn_TextChanged(object sender, EventArgs e)
        {
            GMap.NET.PointLatLng center = gMapControl1.Position;
            String latlngC = Function.ConvertPointLatLngToString(center);


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
            string json = System.Text.Json.JsonSerializer.Serialize(mapConfig);
            string jsonFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "location.json");
            File.WriteAllText(jsonFilePath, json);


        }

        private void InitializeBackgroundWorker()
        {
            backgroundWorkerGeotag = new BackgroundWorker
            {
                WorkerReportsProgress = true
            };
            backgroundWorkerGeotag.DoWork += BackgroundWorkerGeotag_DoWork;
            backgroundWorkerGeotag.ProgressChanged += BackgroundWorkerGeotag_ProgressChanged;
            backgroundWorkerGeotag.RunWorkerCompleted += BackgroundWorkerGeotag_RunWorkerCompleted;


            backgroundWorkerLoadImage = new BackgroundWorker
            {
                WorkerReportsProgress = true
            };
            backgroundWorkerLoadImage.DoWork += backgroundWorkerLoadImage_DoWork;
            backgroundWorkerLoadImage.RunWorkerCompleted
           += backgroundWorkerLoadImage_RunWorkerCompleted;
            backgroundWorkerLoadImage.ProgressChanged += backgroundWorkerLoadImage_ProgressChanged;

            backgroundWorkerLoadImageDate = new BackgroundWorker
            {
                WorkerReportsProgress = true
            };
            backgroundWorkerLoadImageDate.DoWork += BackgroundWorkerLoadImageDate_DoWork;
            backgroundWorkerLoadImageDate.RunWorkerCompleted
              += BackgroundWorkerLoadImageDate_RunWorkerCompleted;
            backgroundWorkerLoadImageDate.ProgressChanged += BackgroundWorkerLoadImageDate_ProgressChanged;

        }
        #region LoadImageDate Background
        private void BackgroundWorkerLoadImageDate_DoWork(object sender, DoWorkEventArgs e)
        {
            notSupportedIndex.Clear();
            newFileNames.Clear();
            lvNameFromDate.ClearItems();
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

            List<string> newFileNameToInsertToListview = new List<string>();
            for (int i = 0; i < filePaths.Count; i++)
            {
                bool isHaveTakenDate = false;
                FileInfo fileInfo = new FileInfo(filePaths[i]);
                DateTime creationTime = fileInfo.CreationTime; // Ngày tạo file
                DateTime lastModifiedTime = fileInfo.LastWriteTime; // Ngày chỉnh sửa cuối cùng
                string newName;

                if (rbFromModified.Checked)
                    newName = prefix + lastModifiedTime.ToString(nameFormat) + suffix;
                else
                    newName = prefix + creationTime.ToString(nameFormat) + suffix;

                if (cbFromDateTaken.Checked && Function.CheckSupported(filePaths[i], supportedGeoTagFormats))
                {
                    using (Image image = Image.FromFile(filePaths[i]))
                    {

                        PropertyItem propItem = null;
                        try
                        {
                            propItem = image.GetPropertyItem(306); // Property tag for Date/Time Original
                        }
                        catch
                        {
                            Console.WriteLine("Can't find properties");
                        }
                        if (propItem != null)
                        {
                            string dateTakenString = Encoding.ASCII.GetString(propItem.Value);
                            string formattedString = dateTakenString.Replace(":", "").Replace(" ", "_").Replace("\0", "");
                            newName = prefix + formattedString + suffix;
                            isHaveTakenDate = true;
                        }
                    }

                }


                if (lengthSequence > 0 && newName != "Error")
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

                string nameIncludeT = newName + Path.GetExtension(filePaths[i]);
                if (isHaveTakenDate)
                    nameIncludeT += " (T)";
                else
                    notSupportedIndex.Add(i);

                newFileNameToInsertToListview.Add(nameIncludeT);
                int progress = (i + 1) * 100 / filePaths.Count;
                backgroundWorkerLoadImageDate.ReportProgress(progress, $"Processing {i + 1} of {filePaths.Count} files...");
            }

            e.Result = newFileNameToInsertToListview;
        }

        private void BackgroundWorkerLoadImageDate_RunWorkerCompleted(object sender, RunWorkerCompletedEventArgs e)
        {
            if (progressFormLoadImageDate != null)
                progressFormLoadImageDate.Close();

            if (e.Error != null)
            {
                // Handle anyerrors during background processing
                MessageBox.Show("Error occurred during processing: " + e.Error.Message);
                return;
            }

            List<string> newFileNameToInsertToListview = (List<string>)e.Result;

            if (notSupportedIndex.Count > 0)
            {
                DialogResult dialogResult = MessageBox.Show($"There are {notSupportedIndex.Count} items that do not have taken date. Do you want to ignore them? If no, that item will be renamed based on the choosen date on the left.", "Warning", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, messageBoxDefaultButtonForFile);
                if (dialogResult == DialogResult.Yes)
                {
                    for (int i = 0; i < notSupportedIndex.Count; i++)
                    {
                        newFileNameToInsertToListview[notSupportedIndex[i]] = "(Ignored) " + newFileNameToInsertToListview[notSupportedIndex[i]];
                    }
                    messageBoxDefaultButtonForFile = MessageBoxDefaultButton.Button1;
                }
                else
                    messageBoxDefaultButtonForFile = MessageBoxDefaultButton.Button2;
            }

            for (int i = 0; i < newFileNameToInsertToListview.Count; i++)
            {
                lvNameFromDate.AddItem(newFileNameToInsertToListview[i]);
                // If the file is supported, bold the text
                // Strike through the item
                if (newFileNameToInsertToListview[i].Contains("(T)"))
                {
                    lvNameFromDate.Items[i].Font = new Font(lvNameFromDate.Font, FontStyle.Bold);
                }

            }
        }

        private void BackgroundWorkerLoadImageDate_ProgressChanged(object sender, ProgressChangedEventArgs e)
        {
            progressFormLoadImageDate.UpdateProgress(e.ProgressPercentage, e.UserState.ToString());
        }



        #endregion


        #region Geotagging
        private void StartProcessingGeotag()
        {
            progressFormGeoTag = new ProgressForm();
            progressFormGeoTag.Show();

            backgroundWorkerGeotag.RunWorkerAsync();
        }

        private void BackgroundWorkerGeotag_DoWork(object sender, DoWorkEventArgs e)
        {
            GMap.NET.PointLatLng center = gMapControl1.Position;
            String latlng = Function.ConvertPointLatLngToString(center);
            mapConfig.Center = center;
            mapConfig.MapType = mapType;
            // Save location to json file for later session
            string json = System.Text.Json.JsonSerializer.Serialize(mapConfig);
            string jsonFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "location.json");
            File.WriteAllText(jsonFilePath, json);

            int totalFiles = filePaths.Count;
            for (int i = 0; i < totalFiles; i++)
            {
                string path = filePaths[i];
                double latitude = center.Lat;
                double longitude = center.Lng;

                if (!Function.CheckSupported(path, supportedGeoTagFormats))
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
            StartProcessingAddMarker(false);

            DialogResult dialog = MessageBox.Show($"Geotagged image saved in _Geotagged folder. Clear list?", "Success", MessageBoxButtons.YesNo, MessageBoxIcon.Information);

            if (dialog == DialogResult.Yes)
                buttonClear_Click(null, null);

        }
        #endregion
        #region LoadImage
        private void backgroundWorkerLoadImage_DoWork(object sender, DoWorkEventArgs e)
        {
            int processedFiles = 0;
            int totalFiles = filePathsToDisplayImage.Count;

            foreach (String filePath in filePathsToDisplayImage)
            {
                // If file not have GPS data, skip it
                if (!Function.CheckSupported(filePath, supportedGeoTagFormats))
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
                CreateMarker(gMapControl1, location.LatLng.Lat, location.LatLng.Lng, location.getLatLngString(), location.Name);
            }
            SimulateMapReload(gMapControl1);

        }

        private void backgroundWorkerLoadImage_ProgressChanged(object sender, ProgressChangedEventArgs e)
        {
            progressFormLoadImage.UpdateProgress(e.ProgressPercentage, e.UserState.ToString());
        }

        private void StartProcessingAddMarker(bool isShowProgress = true)
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
            CreateMarker(gMapControl1, location.LatLng.Lat, location.LatLng.Lng, location.getLatLngString(), location.Name);
            SimulateMapReload(gMapControl1);
        }

        private void ClearMarker()
        {
            gMapControl1.Overlays.Clear();
            gMapControl1.Refresh();
            buttonClear_Click(null, null);
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
                StartProcessingAddMarker(filePathsToDisplayImage.Count > 0);
                btLocationApply.Text = "Clear marker";
            }
            else
            {
                btLocationApply.Text = "Apply";
                if (tabControl1.SelectedTab == tpLocation)
                    buttonClear_Click(null, null);
            }
        }

        #region Save Location

        private void btLocationSave_Click(object sender, EventArgs e)
        {

            if (tbLocationName.Text == "")
            {
                MessageBox.Show("Enter the location name!", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            MyLocation myLocation = new MyLocation(gMapControl1.Position, tbLocationName.Text);
            // If the location latlng already exist, find the index and replace it
            int index = savedLocations.FindIndex(x => x.getLatLngString() == myLocation.getLatLngString());
            if (index == -1)
                savedLocations.Add(myLocation);
            else
                savedLocations[index] = myLocation;

            int indexTag = int.Parse(rtbLocationIndex.Tag.ToString());
            rtbLocationIndex.Text = (indexTag + 1) + "/" + savedLocations.Count;
            WriteSavedLocationToFile();
            //btLocationNext_Click(null, null);
            btLocationSave.Text = "Saved!";
            Task.Delay(2000).ContinueWith(t => btLocationSave.Invoke(new Action(() => btLocationSave.Text = "Save")));
        }

        private void btLocationNext_Click(object sender, EventArgs e)
        {
            if (savedLocations.Count == 0)
                return;
            int index = int.Parse(rtbLocationIndex.Tag.ToString());
            index++;
            if (index >= savedLocations.Count)
                index = 0;
            UpdateIndex(index);
            tbLocationName.Text = savedLocations[index].Name;
            gMapControl1.Position = savedLocations[index].LatLng;
        }

        private void btLocationPrev_Click(object sender, EventArgs e)
        {
            if (savedLocations.Count == 0)
                return;
            int index = int.Parse(rtbLocationIndex.Tag.ToString());
            index--;
            if (index < 0)
                index = savedLocations.Count - 1;
            UpdateIndex(index);
            tbLocationName.Text = savedLocations[index].Name;
            gMapControl1.Position = savedLocations[index].LatLng;
        }

        private void btSavedLocationRemove_Click(object sender, EventArgs e)
        {
            try
            {
                int index = int.Parse(rtbLocationIndex.Tag.ToString());
                savedLocations.RemoveAt(index);
                WriteSavedLocationToFile();
                UpdateIndex(0);
                btSavedLocationRemove.Text = "Removed!";
                Task.Delay(2000).ContinueWith(t => btSavedLocationRemove.Invoke(new Action(() => btSavedLocationRemove.Text = "Remove")));
            }
            catch
            {
                return;
            }
        }


        private void UpdateIndex(int index)
        {
            rtbLocationIndex.Tag = index;
            if (savedLocations.Count == 0)
            {
                rtbLocationIndex.Text = "0/0";
                tbLocationName.Text = "";
                return;
            }
            if (index >= savedLocations.Count)
                index = savedLocations.Count - 1;
            rtbLocationIndex.Text = (index + 1) + "/" + savedLocations.Count;
        }

        public void WriteSavedLocationToFile()
        {
            string json = JsonConvert.SerializeObject(savedLocations, Formatting.Indented);
            File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "saved_locations.json"), json);
        }

        public List<MyLocation> ReadSavedLocationFromFile()
        {
            string jsonFilePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "saved_locations.json");
            if (File.Exists(jsonFilePath))
            {
                string json = File.ReadAllText(jsonFilePath);
                return JsonConvert.DeserializeObject<List<MyLocation>>(json);
            }
            return new List<MyLocation>();
        }
        #endregion

        #endregion
        #endregion

        private void tabControl1_SelectedIndexChanged(object sender, EventArgs e)
        {
            rbDisplayImage.Checked = false;
            rbGeotag.Checked = true;
            cbFromDateTaken.Checked = false;
            if (isScanFolder)
                buttonClear_Click(null, null);
        }

        
    }
}
