using System;
using System.Diagnostics.Eventing.Reader;
using System.Drawing;
using System.Drawing.Imaging;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using ExifLib;
using static System.Windows.Forms.DataFormats;

namespace ExifDataModifier
{
    public partial class Form1 : Form
    {
        private List<string> filePaths = new List<string>();
        private List<DateTime> filePathsDate = new List<DateTime>();
        private Dictionary<string, List<string>> fileGroups = new Dictionary<string, List<string>>();


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
            // Clear previous groups
            fileGroups.Clear();
            fileGroups["other"] = new List<string>();
            cbFileGroup.Items.Clear();

            // Regular expression to match the prefix of the file name up to the first sequence of digits
            Regex regex = new Regex(@"^[^\d]+");

            foreach (string file in files)
            {
                string fileName = Path.GetFileName(file);
                Match match = regex.Match(fileName);

                if (match.Success)
                {
                    string key = match.Value; // This is the group key

                    if (!fileGroups.ContainsKey(key))
                    {
                        fileGroups[key] = new List<string>();
                    }

                    fileGroups[key].Add(file);
                }
                else fileGroups["other"].Add(file);
            }

            // Populate the ComboBox with the first file of each group
            foreach (var group in fileGroups)
            {
               if (group.Key != "other")
                cbFileGroup.Items.Add(Path.GetFileName(group.Value.First()));
            }
            
            if (fileGroups["other"].Count > 0)
                cbFileGroup.Items.Add("Other");

            if (cbFileGroup.Items.Count > 0)
                cbFileGroup.SelectedIndex = 0;
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
                        filePaths.Add(file);
                    }
                    ScanAndGroupFiles(filePaths);
                }
            }
        }

        private void btView_Click(object sender, EventArgs e)
        {
            if (cbFileGroup.SelectedItem != null)
            {
                string firstFileName = cbFileGroup.SelectedItem.ToString(); // Use selected group name

                if (firstFileName == "Other")
                {
                    // Display files in "other" group
                    listBoxFiles.Items.Clear();
                    listBoxName.Items.Clear();
                    foreach (string file in fileGroups["other"])
                    {
                        listBoxName.Items.Add(Path.GetFileName(file));
                        listBoxFiles.Items.Add(file);
                    }
                }
                else
                {

                    Regex regex = new Regex(@"^[^\d]+");
                    Match match = regex.Match(firstFileName);

                    if (match.Success)
                    {
                        string key = match.Value;
                        foreach (var group in fileGroups)
                        {
                            // Check if this group's key matches the extracted key
                            if (group.Key.StartsWith(key))
                            {
                                // Check if the group contains the selected file name
                                if (group.Value.Any(f => Path.GetFileName(f).Equals(firstFileName)))
                                {
                                    listBoxFiles.Items.Clear();
                                    listBoxName.Items.Clear();
                                    foreach (string file in group.Value)
                                    {
                                        listBoxName.Items.Add(Path.GetFileName(file));
                                        listBoxFiles.Items.Add(file);
                                    }
                                    break; // Exit the loop once the matching group is found and processed
                                }
                            }
                        }
                    }
                }
            }
        }

    }

}
