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
    }

}
