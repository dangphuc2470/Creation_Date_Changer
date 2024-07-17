# Creation Date Changer

## Download

Version 1.0: [Release](https://github.com/dangphuc2470/Creation_Date_Changer/releases)

## Problem

You have zipped a large number of photos, and after unzipping them, you lost the creation time. Now, all photo viewers will sort them out of order. That's me this morning!

## Solution

This simple application can fix that. It will extract the creation date from the filename and set it as the new creation date for the image.

## How to Use

### Standard Method
1. **Select Photos**: Choose all photos sharing the same filename format.
2. **Drag and Drop**: Import them into the program by dragging and dropping.
3. **Format Entry**: Input the filename format, substituting all non-date/time characters with "*".
   - Charaters after 'ss' can be ignored.
   - Keep the "Date time format" as per the given example.
4. **Apply Changes**: Hit "Apply" to see a preview of the modifications.
   - Ensure there are no rows marked as "Error".
5. **Finalize Changes**: Click "Change" to confirm the adjustments.

### Folder Scanning Feature
- **Select Folder**: Choose the folder containing your images or videos.
- **Automatic Grouping**: The application will group all images and videos, including those in subfolders, based on their filename. The combobox will display the first item in each group.
- **Manual Selection**: Manually select the desired group, then click "View" to display all items within it.
- **Assign Filename**: Press "Assign" to populate the format textbox with the filename (adjust numbers to their corresponding format letters).
- **Proceed to Step 3**: Follow from step 3 in the Standard Method for further actions.

## Example

- Filename: IMG_20230229_123456.jpg
      Input: `****yyyyMMdd*HHmmss`
- Filename: Project_02_05_2024_20_37_10_1080p_17418_30fps.mp4
      Input: `********MM*dd*yyyy*HH*mm*ss`
## Note

- This application only works for images with filenames that contain the creation date.
- The date format must be consistent for all images.
- The application does not work for file names with certain data missing digits, you can use some tools like Batch File Rename to convert it to the right format: 
  
eg: 

    Screenrecorder-23-08-07-20-28-19-266.mp4

    Screenrecorder-2023-8-7-20-28-19-266.mp4
    
This is the right format: 

    Screenrecorder-2023-08-07-20-28-19-266.mp4

## Screenshot
![Screenshot Description](/Screenshot.png)
