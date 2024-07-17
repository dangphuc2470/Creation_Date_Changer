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
            System.ComponentModel.ComponentResourceManager resources = new System.ComponentModel.ComponentResourceManager(typeof(Form1));
            listBoxFiles = new ListBox();
            buttonSetTime = new Button();
            buttonClear = new Button();
            listBoxExtractedDate = new ListBox();
            listBoxName = new ListBox();
            tbRegex = new TextBox();
            btExtract = new Button();
            label1 = new Label();
            tbDateTimeFormat = new TextBox();
            label4 = new Label();
            panel1 = new Panel();
            panel2 = new Panel();
            tableLayoutPanel2 = new TableLayoutPanel();
            panel3 = new Panel();
            cbShowFullPath = new CheckBox();
            label2 = new Label();
            label3 = new Label();
            panel5 = new Panel();
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
            panel1.SuspendLayout();
            panel2.SuspendLayout();
            tableLayoutPanel2.SuspendLayout();
            panel3.SuspendLayout();
            panel5.SuspendLayout();
            panel4.SuspendLayout();
            ((System.ComponentModel.ISupportInitialize)nmIgnore).BeginInit();
            SuspendLayout();
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
            // buttonSetTime
            // 
            buttonSetTime.Dock = DockStyle.Right;
            buttonSetTime.Location = new Point(438, 5);
            buttonSetTime.Margin = new Padding(0);
            buttonSetTime.Name = "buttonSetTime";
            buttonSetTime.Size = new Size(230, 43);
            buttonSetTime.TabIndex = 1;
            buttonSetTime.Text = "Change";
            buttonSetTime.UseVisualStyleBackColor = true;
            buttonSetTime.Click += buttonSetTime_Click;
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
            // listBoxExtractedDate
            // 
            listBoxExtractedDate.Dock = DockStyle.Fill;
            listBoxExtractedDate.FormattingEnabled = true;
            listBoxExtractedDate.Location = new Point(336, 3);
            listBoxExtractedDate.Name = "listBoxExtractedDate";
            listBoxExtractedDate.Size = new Size(328, 239);
            listBoxExtractedDate.TabIndex = 3;
            // 
            // listBoxName
            // 
            listBoxName.Dock = DockStyle.Fill;
            listBoxName.FormattingEnabled = true;
            listBoxName.HorizontalScrollbar = true;
            listBoxName.Location = new Point(3, 3);
            listBoxName.Name = "listBoxName";
            listBoxName.Size = new Size(327, 239);
            listBoxName.TabIndex = 4;
            listBoxName.SizeChanged += listBoxName_SizeChanged;
            // 
            // tbRegex
            // 
            tbRegex.Location = new Point(9, 39);
            tbRegex.Name = "tbRegex";
            tbRegex.Size = new Size(357, 27);
            tbRegex.TabIndex = 5;
            tbRegex.Text = "***********yyyyMMdd*HHmmss";
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
            // label1
            // 
            label1.AutoSize = true;
            label1.Location = new Point(9, 16);
            label1.Name = "label1";
            label1.Size = new Size(73, 20);
            label1.TabIndex = 7;
            label1.Text = "File name";
            // 
            // tbDateTimeFormat
            // 
            tbDateTimeFormat.Location = new Point(372, 39);
            tbDateTimeFormat.Name = "tbDateTimeFormat";
            tbDateTimeFormat.Size = new Size(181, 27);
            tbDateTimeFormat.TabIndex = 10;
            tbDateTimeFormat.Text = "yyyyMMdd-HHmmss";
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
            // panel1
            // 
            panel1.Controls.Add(buttonClear);
            panel1.Controls.Add(buttonSetTime);
            panel1.Dock = DockStyle.Bottom;
            panel1.Location = new Point(20, 392);
            panel1.Name = "panel1";
            panel1.Padding = new Padding(0, 5, 0, 0);
            panel1.Size = new Size(668, 48);
            panel1.TabIndex = 12;
            // 
            // panel2
            // 
            panel2.Controls.Add(tableLayoutPanel2);
            panel2.Dock = DockStyle.Fill;
            panel2.Location = new Point(20, 20);
            panel2.Name = "panel2";
            panel2.Padding = new Padding(1, 125, 0, 50);
            panel2.Size = new Size(668, 420);
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
            tableLayoutPanel2.Size = new Size(667, 245);
            tableLayoutPanel2.TabIndex = 13;
            // 
            // panel3
            // 
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
            panel3.Size = new Size(668, 125);
            panel3.TabIndex = 14;
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
            // label2
            // 
            label2.AutoSize = true;
            label2.Location = new Point(337, 102);
            label2.Name = "label2";
            label2.Size = new Size(96, 20);
            label2.TabIndex = 8;
            label2.Text = "Date Preview";
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
            // panel5
            // 
            panel5.Controls.Add(listBoxFiles);
            panel5.Controls.Add(panel1);
            panel5.Controls.Add(panel3);
            panel5.Controls.Add(panel2);
            panel5.Dock = DockStyle.Bottom;
            panel5.Location = new Point(0, 231);
            panel5.Margin = new Padding(3, 3, 3, 20);
            panel5.Name = "panel5";
            panel5.Padding = new Padding(20);
            panel5.Size = new Size(708, 460);
            panel5.TabIndex = 12;
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
            panel4.Location = new Point(0, 0);
            panel4.Name = "panel4";
            panel4.Size = new Size(708, 225);
            panel4.TabIndex = 15;
            // 
            // richTextBox1
            // 
            richTextBox1.BackColor = SystemColors.Control;
            richTextBox1.BorderStyle = BorderStyle.None;
            richTextBox1.Location = new Point(206, 147);
            richTextBox1.Name = "richTextBox1";
            richTextBox1.ReadOnly = true;
            richTextBox1.Size = new Size(455, 78);
            richTextBox1.TabIndex = 11;
            richTextBox1.Text = resources.GetString("richTextBox1.Text");
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
            label5.Location = new Point(34, 17);
            label5.Name = "label5";
            label5.Size = new Size(88, 20);
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
            // Form1
            // 
            AutoScaleDimensions = new SizeF(8F, 20F);
            AutoScaleMode = AutoScaleMode.Font;
            ClientSize = new Size(708, 691);
            Controls.Add(panel4);
            Controls.Add(panel5);
            Name = "Form1";
            Text = "Date Changer";
            ResizeEnd += Form1_ResizeEnd;
            panel1.ResumeLayout(false);
            panel2.ResumeLayout(false);
            tableLayoutPanel2.ResumeLayout(false);
            panel3.ResumeLayout(false);
            panel3.PerformLayout();
            panel5.ResumeLayout(false);
            panel4.ResumeLayout(false);
            panel4.PerformLayout();
            ((System.ComponentModel.ISupportInitialize)nmIgnore).EndInit();
            ResumeLayout(false);
        }

        #endregion

        private ListBox listBoxFiles;
        private Button buttonSetTime;
        private Button buttonClear;
        private ListBox listBoxExtractedDate;
        private ListBox listBoxName;
        private TextBox tbRegex;
        private Button btExtract;
        private Label label1;
        private TextBox tbDateTimeFormat;
        private Label label4;
        private Panel panel1;
        private Panel panel2;
        private Panel panel3;
        private Panel panel5;
        private Label label2;
        private Label label3;
        private TableLayoutPanel tableLayoutPanel2;
        private CheckBox cbShowFullPath;
        private Panel panel4;
        private Label label5;
        private TextBox tbPath;
        private Button btChooseFolder;
        private ComboBox cbFileGroup;
        private Label label6;
        private Button btAssign;
        private Button btView;
        private NumericUpDown nmIgnore;
        private Label label8;
        private Label label7;
        private Label label9;
        private RichTextBox richTextBox1;
    }
}
