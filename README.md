# Creation Date Changer

## Download

Version 1.0: [Release](https://github.com/dangphuc2470/Creation_Date_Changer/releases)

## Problem

You have zipped a large number of photos, and after unzipping them, you lost the creation time. Now, all photo viewers will sort them out of order. That's me this morning!

## Solution

This simple application can fix that. It will extract the creation date from the filename and set it as the new creation date for the image.

## How to Use

1. Select all the photos with the same filename format.
2. Drag and drop them into the program.
3. Enter the filename format and replace all characters other than date, month, year, hour, minute, and second with "*".
   - You can ignore characters after the 'ss'.
   - Keep the "Date time format" the same as the example.
4. Click "Apply" to preview the changes.
   - Make sure there are no "Error" rows.
5. Click "Change" to apply the changes.

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
