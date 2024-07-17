using System;
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
        private Dictionary<string, List<string>> fileGroups = new Dictionary<string, List<string>>();
        string[] allowedExtensions = {
    ".jpg", ".jpeg", ".png", ".gif",  // Common image formats
    ".bmp", ".tiff",                 // Less common image formats
    ".webp", ".heic",                 // Modern image formats
    ".raw",                           // RAW image format
    ".psd",                           // Photoshop Document format
    ".ai",                           // Adobe Illustrator Artwork format
    ".svg",                           // Scalable Vector Graphics format

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


        public Form1()
        {
            InitializeComponent();

            AllowDrop = true;
            DragEnter += Form1_DragEnter;
            DragDrop += Form1_DragDrop;
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

            string[] files = (string[])e.Data.GetData(DataFormats.FileDrop);
            filePaths.AddRange(files);
            DisplayFilePaths();
        }

        private void DisplayFilePaths()
        {
            listBoxFiles.Items.Clear();
            listBoxName.Items.Clear();
            foreach (string filePath in filePaths)
            {
                listBoxFiles.Items.Add(filePath);
                listBoxName.Items.Add(Path.GetFileName(filePath));
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
                MessageBox.Show(modifiedName);

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
            filePaths.Clear();
            filePathsDate.Clear();
            listBoxFiles.Items.Clear();
            listBoxName.Items.Clear();
            listBoxExtractedDate.Items.Clear();
        }

        private void btExtract_Click(object sender, EventArgs e)
        {
            filePathsDate.Clear();
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
            MessageBox.Show("Assigned, Please update the number in the filename textbox to match the year, month, day,...", "Info", MessageBoxButtons.OK, MessageBoxIcon.Information);
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
            string modifiedName = name.Substring(0, (int)(length - numberOfLetterToRemove));
            return modifiedName;
        }

    }

}
