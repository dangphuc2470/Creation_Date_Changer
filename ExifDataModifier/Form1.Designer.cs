namespace ExifDataModifier
{
    partial class Form1
    {
        /// <summary>
        ///  Required designer variable.
        /// </summary>
        private System.ComponentModel.IContainer components = null;

        /// <summary>
        ///  Clean up any resources being used.
        /// </summary>
        /// <param name="disposing">true if managed resources should be disposed; otherwise, false.</param>
        protected override void Dispose(bool disposing)
        {
            if (disposing && (components != null))
            {
                components.Dispose();
            }
            base.Dispose(disposing);
        }

        #region Windows Form Designer generated code

        /// <summary>
        ///  Required method for Designer support - do not modify
        ///  the contents of this method with the code editor.
        /// </summary>
        private void InitializeComponent()
        {
            components = new System.ComponentModel.Container();
            System.ComponentModel.ComponentResourceManager resources = new System.ComponentModel.ComponentResourceManager(typeof(Form1));
            tabControl1 = new TabControl();
            tpDate = new TabPage();
            panel5 = new Panel();
            listBoxFiles = new ListBox();
            panel1 = new Panel();
            buttonClear = new Button();
            buttonSetTime = new Button();
            panel3 = new Panel();
            label10 = new Label();
            cbShowFullPath = new CheckBox();
            btExtract = new Button();
            tbRegex = new TextBox();
            label1 = new Label();
            label4 = new Label();
            label2 = new Label();
            tbDateTimeFormat = new TextBox();
            label3 = new Label();
            panel2 = new Panel();
            tableLayoutPanel2 = new TableLayoutPanel();
            listBoxName = new ListBox();
            listBoxExtractedDate = new ListBox();
            panel4 = new Panel();
            richTextBox1 = new RichTextBox();
            label9 = new Label();
            label8 = new Label();
            label7 = new Label();
            nmIgnore = new NumericUpDown();
            btAssign = new Button();
            btView = new Button();
            label6 = new Label();
            cbFileGroup = new ComboBox();
            btChooseFolder = new Button();
            label5 = new Label();
            tbPath = new TextBox();
            tpFilename = new TabPage();
            cbFromDateTaken = new CheckBox();
            label11 = new Label();
            rbFromCreation = new RadioButton();
            rbFromModified = new RadioButton();
            btFileApply = new Button();
            tbFileNameFormat = new TextBox();
            btFileClear = new Button();
            btChangeName = new Button();
            lbNameFromDate = new ListBox();
            lbNameOriginal = new ListBox();
            tpLocation = new TabPage();
            ptbSatelite = new PictureBox();
            tbLatLgn = new TextBox();
            btLocationApply = new Button();
            gMapControl1 = new GMap.NET.WindowsForms.GMapControl();
            panel6 = new Panel();
            groupBox1 = new GroupBox();
            rbDisplayImage = new RadioButton();
            rdGeotag = new RadioButton();
            btLocationClear = new Button();
            lvImageLocation = new ListView();
            imageList1 = new ImageList(components);
            listBox1 = new ListBox();
            tabControl1.SuspendLayout();
            tpDate.SuspendLayout();
            panel5.SuspendLayout();
            panel1.SuspendLayout();
            panel3.SuspendLayout();
            panel2.SuspendLayout();
            tableLayoutPanel2.SuspendLayout();
            panel4.SuspendLayout();
            ((System.ComponentModel.ISupportInitialize)nmIgnore).BeginInit();
            tpFilename.SuspendLayout();
            tpLocation.SuspendLayout();
            ((System.ComponentModel.ISupportInitialize)ptbSatelite).BeginInit();
            panel6.SuspendLayout();
            groupBox1.SuspendLayout();
            SuspendLayout();
            // 
            // tabControl1
            // 
            tabControl1.Controls.Add(tpDate);
            tabControl1.Controls.Add(tpFilename);
            tabControl1.Controls.Add(tpLocation);
            tabControl1.Dock = DockStyle.Fill;
            tabControl1.Location = new Point(0, 0);
            tabControl1.Name = "tabControl1";
            tabControl1.SelectedIndex = 0;
            tabControl1.Size = new Size(708, 725);
            tabControl1.TabIndex = 12;
            // 
            // tpDate
            // 
            tpDate.Controls.Add(panel5);
            tpDate.Controls.Add(panel4);
            tpDate.Location = new Point(4, 29);
            tpDate.Name = "tpDate";
            tpDate.Padding = new Padding(3);
            tpDate.Size = new Size(700, 692);
            tpDate.TabIndex = 0;
            tpDate.Text = "Date";
            tpDate.UseVisualStyleBackColor = true;
            // 
            // panel5
            // 
            panel5.Controls.Add(listBoxFiles);
            panel5.Controls.Add(panel1);
            panel5.Controls.Add(panel3);
            panel5.Controls.Add(panel2);
            panel5.Dock = DockStyle.Bottom;
            panel5.Location = new Point(3, 204);
            panel5.Margin = new Padding(3, 3, 3, 20);
            panel5.Name = "panel5";
            panel5.Padding = new Padding(20);
            panel5.Size = new Size(694, 485);
            panel5.TabIndex = 17;
            // 
            // listBoxFiles
            // 
            listBoxFiles.FormattingEnabled = true;
            listBoxFiles.HorizontalScrollbar = true;
            listBoxFiles.Location = new Point(24, 148);
            listBoxFiles.Name = "listBoxFiles";
            listBoxFiles.Size = new Size(330, 244);
            listBoxFiles.TabIndex = 0;
            listBoxFiles.Visible = false;
            // 
            // panel1
            // 
            panel1.Controls.Add(buttonClear);
            panel1.Controls.Add(buttonSetTime);
            panel1.Dock = DockStyle.Bottom;
            panel1.Location = new Point(20, 417);
            panel1.Name = "panel1";
            panel1.Padding = new Padding(0, 5, 0, 0);
            panel1.Size = new Size(654, 48);
            panel1.TabIndex = 12;
            // 
            // buttonClear
            // 
            buttonClear.Dock = DockStyle.Left;
            buttonClear.Location = new Point(0, 5);
            buttonClear.Name = "buttonClear";
            buttonClear.Size = new Size(169, 43);
            buttonClear.TabIndex = 2;
            buttonClear.Text = "Clear";
            buttonClear.UseVisualStyleBackColor = true;
            buttonClear.Click += buttonClear_Click;
            // 
            // buttonSetTime
            // 
            buttonSetTime.Dock = DockStyle.Right;
            buttonSetTime.Location = new Point(424, 5);
            buttonSetTime.Margin = new Padding(0);
            buttonSetTime.Name = "buttonSetTime";
            buttonSetTime.Size = new Size(230, 43);
            buttonSetTime.TabIndex = 1;
            buttonSetTime.Text = "Change";
            buttonSetTime.UseVisualStyleBackColor = true;
            buttonSetTime.Click += buttonSetTime_Click;
            // 
            // panel3
            // 
            panel3.Controls.Add(label10);
            panel3.Controls.Add(cbShowFullPath);
            panel3.Controls.Add(btExtract);
            panel3.Controls.Add(tbRegex);
            panel3.Controls.Add(label1);
            panel3.Controls.Add(label4);
            panel3.Controls.Add(label2);
            panel3.Controls.Add(tbDateTimeFormat);
            panel3.Controls.Add(label3);
            panel3.Dock = DockStyle.Top;
            panel3.Location = new Point(20, 20);
            panel3.Name = "panel3";
            panel3.Size = new Size(654, 119);
            panel3.TabIndex = 14;
            // 
            // label10
            // 
            label10.AutoSize = true;
            label10.Font = new Font("Segoe UI", 12F, FontStyle.Bold, GraphicsUnit.Point, 0);
            label10.Location = new Point(-7, -9);
            label10.Name = "label10";
            label10.Size = new Size(149, 28);
            label10.TabIndex = 13;
            label10.Text = "Drag and drop";
            // 
            // cbShowFullPath
            // 
            cbShowFullPath.AutoSize = true;
            cbShowFullPath.Location = new Point(9, 72);
            cbShowFullPath.Name = "cbShowFullPath";
            cbShowFullPath.Size = new Size(126, 24);
            cbShowFullPath.TabIndex = 12;
            cbShowFullPath.Text = "Show full path";
            cbShowFullPath.UseVisualStyleBackColor = true;
            cbShowFullPath.CheckedChanged += cbShowFullPath_CheckedChanged;
            // 
            // btExtract
            // 
            btExtract.Location = new Point(559, 39);
            btExtract.Name = "btExtract";
            btExtract.Size = new Size(94, 29);
            btExtract.TabIndex = 6;
            btExtract.Text = "Apply";
            btExtract.UseVisualStyleBackColor = true;
            btExtract.Click += btExtract_Click;
            // 
            // tbRegex
            // 
            tbRegex.Location = new Point(9, 39);
            tbRegex.Name = "tbRegex";
            tbRegex.Size = new Size(357, 27);
            tbRegex.TabIndex = 5;
            tbRegex.Text = "***********yyyyMMdd*HHmmss";
            // 
            // label1
            // 
            label1.AutoSize = true;
            label1.Location = new Point(9, 16);
            label1.Name = "label1";
            label1.Size = new Size(73, 20);
            label1.TabIndex = 7;
            label1.Text = "File name";
            // 
            // label4
            // 
            label4.AutoSize = true;
            label4.Location = new Point(372, 16);
            label4.Name = "label4";
            label4.Size = new Size(124, 20);
            label4.TabIndex = 11;
            label4.Text = "Date time format";
            // 
            // label2
            // 
            label2.AutoSize = true;
            label2.Location = new Point(337, 102);
            label2.Name = "label2";
            label2.Size = new Size(96, 20);
            label2.TabIndex = 8;
            label2.Text = "Date Preview";
            // 
            // tbDateTimeFormat
            // 
            tbDateTimeFormat.Location = new Point(372, 39);
            tbDateTimeFormat.Name = "tbDateTimeFormat";
            tbDateTimeFormat.Size = new Size(181, 27);
            tbDateTimeFormat.TabIndex = 10;
            tbDateTimeFormat.Text = "yyyyMMdd-HHmmss";
            // 
            // label3
            // 
            label3.AutoSize = true;
            label3.Location = new Point(14, 102);
            label3.Name = "label3";
            label3.Size = new Size(73, 20);
            label3.TabIndex = 9;
            label3.Text = "File name";
            // 
            // panel2
            // 
            panel2.Controls.Add(tableLayoutPanel2);
            panel2.Dock = DockStyle.Fill;
            panel2.Location = new Point(20, 20);
            panel2.Name = "panel2";
            panel2.Padding = new Padding(1, 125, 0, 50);
            panel2.Size = new Size(654, 445);
            panel2.TabIndex = 13;
            // 
            // tableLayoutPanel2
            // 
            tableLayoutPanel2.ColumnCount = 2;
            tableLayoutPanel2.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            tableLayoutPanel2.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            tableLayoutPanel2.Controls.Add(listBoxName, 0, 0);
            tableLayoutPanel2.Controls.Add(listBoxExtractedDate, 1, 0);
            tableLayoutPanel2.Dock = DockStyle.Fill;
            tableLayoutPanel2.Location = new Point(1, 125);
            tableLayoutPanel2.Name = "tableLayoutPanel2";
            tableLayoutPanel2.RowCount = 1;
            tableLayoutPanel2.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));
            tableLayoutPanel2.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));
            tableLayoutPanel2.RowStyles.Add(new RowStyle(SizeType.Absolute, 20F));
            tableLayoutPanel2.Size = new Size(653, 270);
            tableLayoutPanel2.TabIndex = 13;
            // 
            // listBoxName
            // 
            listBoxName.Dock = DockStyle.Fill;
            listBoxName.FormattingEnabled = true;
            listBoxName.HorizontalScrollbar = true;
            listBoxName.Location = new Point(3, 3);
            listBoxName.Name = "listBoxName";
            listBoxName.Size = new Size(320, 264);
            listBoxName.TabIndex = 4;
            // 
            // listBoxExtractedDate
            // 
            listBoxExtractedDate.Dock = DockStyle.Fill;
            listBoxExtractedDate.FormattingEnabled = true;
            listBoxExtractedDate.Location = new Point(329, 3);
            listBoxExtractedDate.Name = "listBoxExtractedDate";
            listBoxExtractedDate.Size = new Size(321, 264);
            listBoxExtractedDate.TabIndex = 3;
            // 
            // panel4
            // 
            panel4.Controls.Add(richTextBox1);
            panel4.Controls.Add(label9);
            panel4.Controls.Add(label8);
            panel4.Controls.Add(label7);
            panel4.Controls.Add(nmIgnore);
            panel4.Controls.Add(btAssign);
            panel4.Controls.Add(btView);
            panel4.Controls.Add(label6);
            panel4.Controls.Add(cbFileGroup);
            panel4.Controls.Add(btChooseFolder);
            panel4.Controls.Add(label5);
            panel4.Controls.Add(tbPath);
            panel4.Dock = DockStyle.Top;
            panel4.Location = new Point(3, 3);
            panel4.Name = "panel4";
            panel4.Size = new Size(694, 225);
            panel4.TabIndex = 16;
            // 
            // richTextBox1
            // 
            richTextBox1.BackColor = Color.WhiteSmoke;
            richTextBox1.BorderStyle = BorderStyle.None;
            richTextBox1.Location = new Point(200, 147);
            richTextBox1.Name = "richTextBox1";
            richTextBox1.ReadOnly = true;
            richTextBox1.Size = new Size(489, 48);
            richTextBox1.TabIndex = 11;
            richTextBox1.Text = "If your file name have HEX number at the end, use this to ignore it \n(Don't count the file extension)";
            // 
            // label9
            // 
            label9.AutoSize = true;
            label9.Location = new Point(200, 187);
            label9.Name = "label9";
            label9.Size = new Size(0, 20);
            label9.TabIndex = 10;
            // 
            // label8
            // 
            label8.AutoSize = true;
            label8.Location = new Point(200, 167);
            label8.Name = "label8";
            label8.Size = new Size(0, 20);
            label8.TabIndex = 9;
            // 
            // label7
            // 
            label7.AutoSize = true;
            label7.Location = new Point(29, 144);
            label7.Name = "label7";
            label7.Size = new Size(142, 20);
            label7.TabIndex = 8;
            label7.Text = "Ignore from the end";
            // 
            // nmIgnore
            // 
            nmIgnore.Location = new Point(34, 167);
            nmIgnore.Name = "nmIgnore";
            nmIgnore.Size = new Size(150, 27);
            nmIgnore.TabIndex = 7;
            // 
            // btAssign
            // 
            btAssign.Location = new Point(558, 103);
            btAssign.Name = "btAssign";
            btAssign.Size = new Size(94, 29);
            btAssign.TabIndex = 6;
            btAssign.Text = "Assign";
            btAssign.UseVisualStyleBackColor = true;
            btAssign.Click += btAssign_Click;
            // 
            // btView
            // 
            btView.Location = new Point(458, 103);
            btView.Name = "btView";
            btView.Size = new Size(94, 29);
            btView.TabIndex = 5;
            btView.Text = "View";
            btView.UseVisualStyleBackColor = true;
            btView.Click += btView_Click;
            // 
            // label6
            // 
            label6.AutoSize = true;
            label6.Location = new Point(34, 80);
            label6.Name = "label6";
            label6.Size = new Size(165, 20);
            label6.TabIndex = 4;
            label6.Text = "File name format found";
            // 
            // cbFileGroup
            // 
            cbFileGroup.FormattingEnabled = true;
            cbFileGroup.Location = new Point(34, 103);
            cbFileGroup.Name = "cbFileGroup";
            cbFileGroup.Size = new Size(418, 28);
            cbFileGroup.TabIndex = 3;
            // 
            // btChooseFolder
            // 
            btChooseFolder.Location = new Point(303, 44);
            btChooseFolder.Name = "btChooseFolder";
            btChooseFolder.Size = new Size(132, 29);
            btChooseFolder.TabIndex = 2;
            btChooseFolder.Text = "Choose folder";
            btChooseFolder.UseVisualStyleBackColor = true;
            btChooseFolder.Click += btChooseFolder_Click;
            // 
            // label5
            // 
            label5.AutoSize = true;
            label5.Font = new Font("Segoe UI", 12F, FontStyle.Bold);
            label5.Location = new Point(17, 7);
            label5.Name = "label5";
            label5.Size = new Size(127, 28);
            label5.TabIndex = 1;
            label5.Text = "Scan for file";
            // 
            // tbPath
            // 
            tbPath.Location = new Point(34, 44);
            tbPath.Name = "tbPath";
            tbPath.Size = new Size(263, 27);
            tbPath.TabIndex = 0;
            // 
            // tpFilename
            // 
            tpFilename.Controls.Add(cbFromDateTaken);
            tpFilename.Controls.Add(label11);
            tpFilename.Controls.Add(rbFromCreation);
            tpFilename.Controls.Add(rbFromModified);
            tpFilename.Controls.Add(btFileApply);
            tpFilename.Controls.Add(tbFileNameFormat);
            tpFilename.Controls.Add(btFileClear);
            tpFilename.Controls.Add(btChangeName);
            tpFilename.Controls.Add(lbNameFromDate);
            tpFilename.Controls.Add(lbNameOriginal);
            tpFilename.Location = new Point(4, 29);
            tpFilename.Name = "tpFilename";
            tpFilename.Padding = new Padding(3);
            tpFilename.Size = new Size(700, 692);
            tpFilename.TabIndex = 1;
            tpFilename.Text = "Filename";
            tpFilename.UseVisualStyleBackColor = true;
            // 
            // cbFromDateTaken
            // 
            cbFromDateTaken.AutoSize = true;
            cbFromDateTaken.Location = new Point(390, 83);
            cbFromDateTaken.Name = "cbFromDateTaken";
            cbFromDateTaken.Size = new Size(211, 24);
            cbFromDateTaken.TabIndex = 9;
            cbFromDateTaken.Tag = "Uncheck";
            cbFromDateTaken.Text = "From date taken if possible";
            cbFromDateTaken.UseVisualStyleBackColor = true;
            cbFromDateTaken.CheckedChanged += cbFromDateTaken_CheckedChanged;
            // 
            // label11
            // 
            label11.AutoSize = true;
            label11.Location = new Point(24, 23);
            label11.Name = "label11";
            label11.Size = new Size(122, 20);
            label11.TabIndex = 8;
            label11.Text = "File name format";
            // 
            // rbFromCreation
            // 
            rbFromCreation.AutoSize = true;
            rbFromCreation.Location = new Point(216, 83);
            rbFromCreation.Name = "rbFromCreation";
            rbFromCreation.Size = new Size(152, 24);
            rbFromCreation.TabIndex = 7;
            rbFromCreation.TabStop = true;
            rbFromCreation.Text = "From created date";
            rbFromCreation.UseVisualStyleBackColor = true;
            rbFromCreation.Click += rbFromModified_Click;
            // 
            // rbFromModified
            // 
            rbFromModified.AutoSize = true;
            rbFromModified.Checked = true;
            rbFromModified.Location = new Point(24, 83);
            rbFromModified.Name = "rbFromModified";
            rbFromModified.Size = new Size(163, 24);
            rbFromModified.TabIndex = 6;
            rbFromModified.TabStop = true;
            rbFromModified.Text = "From modified date";
            rbFromModified.UseVisualStyleBackColor = true;
            rbFromModified.Click += rbFromModified_Click;
            // 
            // btFileApply
            // 
            btFileApply.Location = new Point(365, 46);
            btFileApply.Name = "btFileApply";
            btFileApply.Size = new Size(94, 29);
            btFileApply.TabIndex = 5;
            btFileApply.Text = "Preview";
            btFileApply.UseVisualStyleBackColor = true;
            btFileApply.Click += btFileApply_Click;
            // 
            // tbFileNameFormat
            // 
            tbFileNameFormat.Location = new Point(24, 46);
            tbFileNameFormat.Name = "tbFileNameFormat";
            tbFileNameFormat.Size = new Size(316, 27);
            tbFileNameFormat.TabIndex = 4;
            tbFileNameFormat.Text = "IMG_<yyyyMMdd_HHmmss>_[nnnn]";
            // 
            // btFileClear
            // 
            btFileClear.Location = new Point(24, 627);
            btFileClear.Name = "btFileClear";
            btFileClear.Size = new Size(316, 44);
            btFileClear.TabIndex = 3;
            btFileClear.Text = "Clear";
            btFileClear.UseVisualStyleBackColor = true;
            btFileClear.Click += buttonClear_Click;
            // 
            // btChangeName
            // 
            btChangeName.Location = new Point(365, 627);
            btChangeName.Name = "btChangeName";
            btChangeName.Size = new Size(309, 44);
            btChangeName.TabIndex = 2;
            btChangeName.Text = "Apply name";
            btChangeName.UseVisualStyleBackColor = true;
            btChangeName.Click += btChangeName_Click;
            // 
            // lbNameFromDate
            // 
            lbNameFromDate.FormattingEnabled = true;
            lbNameFromDate.Location = new Point(365, 117);
            lbNameFromDate.Name = "lbNameFromDate";
            lbNameFromDate.Size = new Size(309, 504);
            lbNameFromDate.TabIndex = 1;
            // 
            // lbNameOriginal
            // 
            lbNameOriginal.FormattingEnabled = true;
            lbNameOriginal.Location = new Point(24, 117);
            lbNameOriginal.Name = "lbNameOriginal";
            lbNameOriginal.Size = new Size(316, 504);
            lbNameOriginal.TabIndex = 0;
            // 
            // tpLocation
            // 
            tpLocation.Controls.Add(ptbSatelite);
            tpLocation.Controls.Add(tbLatLgn);
            tpLocation.Controls.Add(btLocationApply);
            tpLocation.Controls.Add(gMapControl1);
            tpLocation.Controls.Add(panel6);
            tpLocation.Location = new Point(4, 29);
            tpLocation.Name = "tpLocation";
            tpLocation.Padding = new Padding(3);
            tpLocation.Size = new Size(700, 692);
            tpLocation.TabIndex = 2;
            tpLocation.Text = "Location";
            tpLocation.UseVisualStyleBackColor = true;
            // 
            // ptbSatelite
            // 
            ptbSatelite.Image = Properties.Resources.download;
            ptbSatelite.Location = new Point(358, 541);
            ptbSatelite.Name = "ptbSatelite";
            ptbSatelite.Size = new Size(52, 43);
            ptbSatelite.SizeMode = PictureBoxSizeMode.Zoom;
            ptbSatelite.TabIndex = 5;
            ptbSatelite.TabStop = false;
            ptbSatelite.Click += ptbSatelite_Click;
            // 
            // tbLatLgn
            // 
            tbLatLgn.BorderStyle = BorderStyle.FixedSingle;
            tbLatLgn.Location = new Point(358, 590);
            tbLatLgn.Name = "tbLatLgn";
            tbLatLgn.Size = new Size(184, 27);
            tbLatLgn.TabIndex = 4;
            tbLatLgn.TextChanged += tbLatLgn_TextChanged;
            // 
            // btLocationApply
            // 
            btLocationApply.FlatStyle = FlatStyle.Flat;
            btLocationApply.Location = new Point(358, 635);
            btLocationApply.Name = "btLocationApply";
            btLocationApply.Size = new Size(336, 51);
            btLocationApply.TabIndex = 3;
            btLocationApply.Text = "Apply";
            btLocationApply.UseVisualStyleBackColor = true;
            btLocationApply.Click += btLocationApply_Click;
            // 
            // gMapControl1
            // 
            gMapControl1.Bearing = 0F;
            gMapControl1.CanDragMap = true;
            gMapControl1.Dock = DockStyle.Fill;
            gMapControl1.EmptyTileColor = Color.Navy;
            gMapControl1.GrayScaleMode = false;
            gMapControl1.HelperLineOption = GMap.NET.WindowsForms.HelperLineOptions.DontShow;
            gMapControl1.LevelsKeepInMemory = 5;
            gMapControl1.Location = new Point(356, 3);
            gMapControl1.MarkersEnabled = true;
            gMapControl1.MaxZoom = 2;
            gMapControl1.MinZoom = 2;
            gMapControl1.MouseWheelZoomEnabled = true;
            gMapControl1.MouseWheelZoomType = GMap.NET.MouseWheelZoomType.MousePositionAndCenter;
            gMapControl1.Name = "gMapControl1";
            gMapControl1.NegativeMode = false;
            gMapControl1.PolygonsEnabled = true;
            gMapControl1.RetryLoadTile = 0;
            gMapControl1.RoutesEnabled = true;
            gMapControl1.ScaleMode = GMap.NET.WindowsForms.ScaleModes.Integer;
            gMapControl1.SelectedAreaFillColor = Color.FromArgb(33, 65, 105, 225);
            gMapControl1.ShowTileGridLines = false;
            gMapControl1.Size = new Size(341, 686);
            gMapControl1.TabIndex = 2;
            gMapControl1.Zoom = 0D;
            gMapControl1.MouseMove += gMapControl1_MouseUp;
            // 
            // panel6
            // 
            panel6.Controls.Add(groupBox1);
            panel6.Controls.Add(btLocationClear);
            panel6.Controls.Add(lvImageLocation);
            panel6.Dock = DockStyle.Left;
            panel6.Location = new Point(3, 3);
            panel6.Name = "panel6";
            panel6.Size = new Size(353, 686);
            panel6.TabIndex = 1;
            // 
            // groupBox1
            // 
            groupBox1.Controls.Add(rbDisplayImage);
            groupBox1.Controls.Add(rdGeotag);
            groupBox1.Location = new Point(5, 548);
            groupBox1.Name = "groupBox1";
            groupBox1.Size = new Size(342, 50);
            groupBox1.TabIndex = 4;
            groupBox1.TabStop = false;
            groupBox1.Text = "Mode";
            // 
            // rbDisplayImage
            // 
            rbDisplayImage.AutoSize = true;
            rbDisplayImage.Location = new Point(105, 20);
            rbDisplayImage.Name = "rbDisplayImage";
            rbDisplayImage.Size = new Size(131, 24);
            rbDisplayImage.TabIndex = 1;
            rbDisplayImage.Text = "Display Images";
            rbDisplayImage.UseVisualStyleBackColor = true;
            rbDisplayImage.CheckedChanged += rbDisplayImage_CheckedChanged;
            // 
            // rdGeotag
            // 
            rdGeotag.AutoSize = true;
            rdGeotag.Checked = true;
            rdGeotag.Location = new Point(6, 20);
            rdGeotag.Name = "rdGeotag";
            rdGeotag.Size = new Size(79, 24);
            rdGeotag.TabIndex = 0;
            rdGeotag.TabStop = true;
            rdGeotag.Text = "Geotag";
            rdGeotag.UseVisualStyleBackColor = true;
            // 
            // btLocationClear
            // 
            btLocationClear.Location = new Point(5, 632);
            btLocationClear.Name = "btLocationClear";
            btLocationClear.Size = new Size(345, 51);
            btLocationClear.TabIndex = 1;
            btLocationClear.Text = "Clear";
            btLocationClear.UseVisualStyleBackColor = true;
            btLocationClear.Click += buttonClear_Click;
            // 
            // lvImageLocation
            // 
            lvImageLocation.LargeImageList = imageList1;
            lvImageLocation.Location = new Point(-169, -2);
            lvImageLocation.Margin = new Padding(0);
            lvImageLocation.Name = "lvImageLocation";
            lvImageLocation.Size = new Size(519, 541);
            lvImageLocation.SmallImageList = imageList1;
            lvImageLocation.Sorting = SortOrder.Ascending;
            lvImageLocation.StateImageList = imageList1;
            lvImageLocation.TabIndex = 0;
            lvImageLocation.UseCompatibleStateImageBehavior = false;
            lvImageLocation.View = View.SmallIcon;
            // 
            // imageList1
            // 
            imageList1.ColorDepth = ColorDepth.Depth16Bit;
            imageList1.ImageSize = new Size(100, 100);
            imageList1.TransparentColor = Color.Transparent;
            // 
            // listBox1
            // 
            listBox1.FormattingEnabled = true;
            listBox1.Location = new Point(643, 728);
            listBox1.Name = "listBox1";
            listBox1.Size = new Size(150, 104);
            listBox1.TabIndex = 13;
            // 
            // Form1
            // 
            AutoScaleDimensions = new SizeF(8F, 20F);
            AutoScaleMode = AutoScaleMode.Font;
            ClientSize = new Size(708, 725);
            Controls.Add(listBox1);
            Controls.Add(tabControl1);
            Icon = (Icon)resources.GetObject("$this.Icon");
            Name = "Form1";
            Text = "Date Changer";
            ResizeEnd += Form1_ResizeEnd;
            DragDrop += Form1_DragDrop;
            DragEnter += Form1_DragEnter;
            tabControl1.ResumeLayout(false);
            tpDate.ResumeLayout(false);
            panel5.ResumeLayout(false);
            panel1.ResumeLayout(false);
            panel3.ResumeLayout(false);
            panel3.PerformLayout();
            panel2.ResumeLayout(false);
            tableLayoutPanel2.ResumeLayout(false);
            panel4.ResumeLayout(false);
            panel4.PerformLayout();
            ((System.ComponentModel.ISupportInitialize)nmIgnore).EndInit();
            tpFilename.ResumeLayout(false);
            tpFilename.PerformLayout();
            tpLocation.ResumeLayout(false);
            tpLocation.PerformLayout();
            ((System.ComponentModel.ISupportInitialize)ptbSatelite).EndInit();
            panel6.ResumeLayout(false);
            groupBox1.ResumeLayout(false);
            groupBox1.PerformLayout();
            ResumeLayout(false);
        }

        #endregion

        private TabControl tabControl1;
        private TabPage tpDate;
        private Panel panel5;
        private ListBox listBoxFiles;
        private Panel panel1;
        private Button buttonClear;
        private Button buttonSetTime;
        private Panel panel3;
        private CheckBox cbShowFullPath;
        private Button btExtract;
        private TextBox tbRegex;
        private Label label1;
        private Label label4;
        private Label label2;
        private TextBox tbDateTimeFormat;
        private Label label3;
        private Panel panel2;
        private TableLayoutPanel tableLayoutPanel2;
        private ListBox listBoxName;
        private ListBox listBoxExtractedDate;
        private Panel panel4;
        private RichTextBox richTextBox1;
        private Label label9;
        private Label label8;
        private Label label7;
        private NumericUpDown nmIgnore;
        private Button btAssign;
        private Button btView;
        private Label label6;
        private ComboBox cbFileGroup;
        private Button btChooseFolder;
        private Label label5;
        private TextBox tbPath;
        private TabPage tpFilename;
        private Label label10;
        private ListBox lbNameFromDate;
        private ListBox lbNameOriginal;
        private Button btFileClear;
        private Button btChangeName;
        private RadioButton rbFromCreation;
        private RadioButton rbFromModified;
        private Button btFileApply;
        private TextBox tbFileNameFormat;
        private Label label11;
        private TabPage tpLocation;
        private ImageList imageList1;
        private ListView lvImageLocation;
        private Panel panel6;
        private Button btLocationClear;
        private GMap.NET.WindowsForms.GMapControl gMapControl1;
        private Button btLocationApply;
        private TextBox tbLatLgn;
        private PictureBox ptbSatelite;
        private GroupBox groupBox1;
        private RadioButton rdGeotag;
        private RadioButton rbDisplayImage;
        private ListBox listBox1;
        private CheckBox cbFromDateTaken;
    }
}
