using System;
using System.Collections.Generic;
using System.Diagnostics.Eventing.Reader;
using System.Drawing;
using System.Drawing.Imaging;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using ExifLib;
using static System.Windows.Forms.DataFormats;
using static System.Windows.Forms.VisualStyles.VisualStyleElement.Button;

namespace ExifDataModifier
{
    public partial class Form1 : Form
    {
        private List<string> filePaths = new List<string>();
        private List<DateTime> filePathsDate = new List<DateTime>();
        private List<string> newFileNames = new List<string>();
        private Dictionary<string, List<string>> fileGroups = new Dictionary<string, List<string>>();
        private bool isShowNotificationFirstTime = false;
        private volatile bool stopRequested = false;
        string[] allowedExtensions = {
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
        string[] imageExtensions =
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


        public Form1()
        {
            InitializeComponent();
            AllowDrop = true;
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
            DisplayFilePaths();
        }

        private void DisplayFilePaths()
        {
            listBoxFiles.Items.Clear();
            listBoxName.Items.Clear();
            lbNameFromDate.Items.Clear();
            lbNameOriginal.Items.Clear();
            foreach (string filePath in filePaths)
            {
                listBoxFiles.Items.Add(filePath);
                listBoxName.Items.Add(Path.GetFileName(filePath));
                lbNameOriginal.Items.Add(Path.GetFileName(filePath));
            }

            LoadImagesIntoListView(filePaths);
            //for (int i = 0; i < newFileNames.Count; i++)
            //{
            //    lbNameFromDate.Items.Add(newFileNames[i] + Path.GetExtension(filePaths[i]));
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
            MessageBox.Show("Set time successfully!");
        }

        private void buttonClear_Click(object sender, EventArgs e)
        {
            stopRequested = true;
            filePaths.Clear();
            filePathsDate.Clear();
            listBoxFiles.Items.Clear();
            listBoxName.Items.Clear();
            listBoxExtractedDate.Items.Clear();
            lbNameFromDate.Items.Clear();
            lbNameOriginal.Items.Clear();
            lvImageLocation.Items.Clear();
        }

        private void btExtract_Click(object sender, EventArgs e)
        {
            filePathsDate.Clear();
            if (listBoxFiles.Items.Count == 0)
            {
                MessageBox.Show("Nothing to apply");
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
                        string extension = Path.GetExtension(file).ToLower();
                        // Make sure it only add the Image and Video
                        if (allowedExtensions.Contains(extension))
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
                    MessageBox.Show("Please check the format!");
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

                MessageBox.Show("Success!");
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
                    if (!imageExtensions.Contains(Path.GetExtension(path).ToLower()))
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
                    Image resizedImage = ResizeImage(originalImage, imageList1.ImageSize.Width, imageList1.ImageSize.Height);

                    // Marshal the UI update back to the UI thread
                    this.Invoke((MethodInvoker)delegate
                    {
                        int imageIndex = imageList1.Images.Count;
                        imageList1.Images.Add(resizedImage);

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
                        MessageBox.Show($"Error loading image: {ex.Message}");
                    });
                }
            });
            this.Invoke((MethodInvoker)delegate
            {
                lvImageLocation.EndUpdate(); // Ends the update process and repaints the ListView if necessary.
            });
        }


        private Image ResizeImage(Image image, int width, int height)
        {
            // Correct orientation
            image = CorrectImageOrientation(image);

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
    }

}
