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
            label2 = new Label();
            label3 = new Label();
            panel5 = new Panel();
            panel1.SuspendLayout();
            panel2.SuspendLayout();
            tableLayoutPanel2.SuspendLayout();
            panel3.SuspendLayout();
            panel5.SuspendLayout();
            SuspendLayout();
            // 
            // listBoxFiles
            // 
            listBoxFiles.FormattingEnabled = true;
            listBoxFiles.Location = new Point(-174, 126);
            listBoxFiles.Name = "listBoxFiles";
            listBoxFiles.Size = new Size(150, 224);
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
            listBoxExtractedDate.Size = new Size(328, 363);
            listBoxExtractedDate.TabIndex = 3;
            // 
            // listBoxName
            // 
            listBoxName.Dock = DockStyle.Fill;
            listBoxName.FormattingEnabled = true;
            listBoxName.Location = new Point(3, 3);
            listBoxName.Name = "listBoxName";
            listBoxName.Size = new Size(327, 363);
            listBoxName.TabIndex = 4;
            // 
            // tbRegex
            // 
            tbRegex.Location = new Point(9, 39);
            tbRegex.Name = "tbRegex";
            tbRegex.Size = new Size(357, 27);
            tbRegex.TabIndex = 5;
            tbRegex.Text = "***********yyyyMMdd-HHmmss";
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
            panel1.Location = new Point(20, 516);
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
            panel2.Size = new Size(668, 544);
            panel2.TabIndex = 13;
            // 
            // tableLayoutPanel2
            // 
            tableLayoutPanel2.ColumnCount = 2;
            tableLayoutPanel2.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            tableLayoutPanel2.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            tableLayoutPanel2.Controls.Add(listBoxExtractedDate, 0, 0);
            tableLayoutPanel2.Controls.Add(listBoxName, 0, 0);
            tableLayoutPanel2.Dock = DockStyle.Fill;
            tableLayoutPanel2.Location = new Point(1, 125);
            tableLayoutPanel2.Name = "tableLayoutPanel2";
            tableLayoutPanel2.RowCount = 1;
            tableLayoutPanel2.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));
            tableLayoutPanel2.RowStyles.Add(new RowStyle(SizeType.Percent, 50F));
            tableLayoutPanel2.Size = new Size(667, 369);
            tableLayoutPanel2.TabIndex = 13;
            // 
            // panel3
            // 
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
            panel5.Controls.Add(panel1);
            panel5.Controls.Add(panel3);
            panel5.Controls.Add(panel2);
            panel5.Dock = DockStyle.Fill;
            panel5.Location = new Point(0, 0);
            panel5.Margin = new Padding(3, 3, 3, 20);
            panel5.Name = "panel5";
            panel5.Padding = new Padding(20);
            panel5.Size = new Size(708, 584);
            panel5.TabIndex = 12;
            // 
            // Form1
            // 
            AutoScaleDimensions = new SizeF(8F, 20F);
            AutoScaleMode = AutoScaleMode.Font;
            ClientSize = new Size(708, 584);
            Controls.Add(panel5);
            Controls.Add(listBoxFiles);
            Name = "Form1";
            Text = "Date Changer";
            panel1.ResumeLayout(false);
            panel2.ResumeLayout(false);
            tableLayoutPanel2.ResumeLayout(false);
            panel3.ResumeLayout(false);
            panel3.PerformLayout();
            panel5.ResumeLayout(false);
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
    }
}
