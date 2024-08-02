# Creation Date Changer
This application allows you to change the creation and modified date of files based on their filename. It also allows you to change the filename based on the creation date, modified date, or date taken of an image. Additionally, you can add GPS data to images and display them on a map.

# Requirements
- Microsoft .NET 8.0 Desktop Runtime: [Download  here](https://dotnet.microsoft.com/download/dotnet/8.0/runtime), Download Desktop Runtime version.

# Features
### Change created and modified date of files based on their filename
- Extract the date and time from the filename and apply it to the file's metadata.
- Supported extensions for drag-and-drop: All file types.
- Supported extensions for scanning folder: `jpg`, `jpeg`, `png`, `gif`, `bmp`, `tiff`, `webp`, `heic`, `raw`, `psd`, `ai`, `svg`, `cr2`, `nef`, `arw`, `orf`, `pef`, `dng`, `mp4`, `mov`, `avi`, `mkv`, `wmv`, `flv`, `webm`, `avchd`, `mpeg2`, `vp9`, `h263`, `prores`, `tga`, `flic`.

## Change filename based on creation date, modified date, or date taken of an image
- Extract the date and time from the file's metadata and apply it to the filename, file extension will be preserved.
- Supported extensions for drag-and-drop: All file types.
- Supported extensions for image that have taken date: `.jpg`, `.jpeg`, `.tiff`, `.webp`, `.heic`.

## Geotag
- Add GPS data to images base on user input.
- Show image on map based on GPS data.
- Supported extensions for drag-and-drop: `.jpg`, `.jpeg`, `.tiff`, `.webp`, `.heic`.


# Download

**Version 1.2: [Release](https://github.com/dangphuc2470/Creation_Date_Changer/releases)**


# Change log
**[1.2] - 2024/08/01**
- Feature: Display image on map, Geotag
- Bug fixes

**[1.1] - 2024/07/17**
- Feature: Folder Scanning

**[1.0] - 2024/02/29**
- Feature: Change created and modified date

# How to Use

**A. Normal method**
1. Download the zip file in the release section.
2. Extract the zip file.
3. Run the `ExifDataModifier.exe` file.

**B. Run from source code**
1. Install .NET desktop development workload in Visual Studio if you haven't installed it.
2. Clone the repository.
3. Open the solution file in Visual Studio.
4. Run the project.

## I. Change created and modified date
 <span style="color:red" >**Important Note**</span>
- **This feature will overwrite the original file, please make sure to backup your files before using it.**

![Screenshot Description](/screenshot/created_modified.png)
### A. Standard Method
1. **Select Photos**: Choose all photos sharing the same filename format.
2. **Drag and Drop**: Import them into the program by dragging and dropping.
3. **Format Entry**: 
   - Input the filename format (or use the assign button above), substituting all non-date/time characters with "*".
   - Charaters after 'ss' can be ignored.
   - Keep the "Date time format" as per the given example.
4. **Preview**: 
   - Click "Apply" to see the date and time extracted from the filename.
   - Make sure there are no rows marked as "Error".
5. **Apply Changes**: Click "Change" to confirm the adjustments.

### B. Folder Scanning Feature
1. **Select Folder**: Choose the folder containing your images or videos.
2. **Automatic Grouping**: The application will group all images and videos, including those in subfolders, based on their filename. The combobox will display the first item in each group.
    - **Note:** If your file name have suffix at the end and it include both letters and numbers, the application will split it into different groups.
    You can use the "Ignore" section to ignore the suffix.
    eg:
    
    ```
    IMG_20240606_130614_A02BFA00.JPG    Ignore: 8

    IMG_20240606_130614_00000001.JPG    Ignore: 0 (no need to ignore numbers)
    
    Screenshot_2023-07-21-18-04-24-351_com.miui.home.jpg 
    Ignore: 0 (no need to ignore, there are no string between "_" have both letters and numbers)
    
    ```
    ![Screenshot Description](/screenshot/ignore.png)
3. **Manual Selection**: Manually select the desired group, then click "View" to display all items within it.
4. **Proceed to Step 3**: Follow from step 3 in the Standard Method for further actions.

**Example Usage**

- Filename: IMG_20230229_123456.jpg
    - Input: `****yyyyMMdd*HHmmss`
- Filename: Project_02_05_2024_20_37_10_1080p_17418_30fps.mp4
    - Input: `********MM*dd*yyyy*HH*mm*ss`

## Note
- The feature does not work for file names with certain data missing digits, you can use some tools like Batch File Rename to convert it to the right format: 
  
eg: 

    Screenrecorder-23-08-07-20-28-19-266.mp4

    Screenrecorder-2023-8-7-20-28-19-266.mp4
    
This is the right format: 

    Screenrecorder-2023-08-07-20-28-19-266.mp4

## II. Change filename
 <span style="color:red" >**Important Note**</span>
- **This feature will overwrite the original file, please make sure to backup your files before using it.**
- Get date taken feature is not well optimized, it may not work well with a large number of images.
- Extensions that have taken date exif data: `.jpg`, `.jpeg`, `.tiff`, `.webp`, `.heic`.

![Screenshot Description](/screenshot/filename.png)
1. **Select Photos**: Choose all photos that you want to change the filename.
2. **Drag and Drop**: Import them into the program by dragging and dropping.
3. **Select Option**: Choose the desired option: 
    - **Creation Date**: Change the filename based on the creation date.
    - **Modified Date**: Change the filename based on the modified date.
    - **Date Taken**: Change the filename based on the date taken, a message box will appear if have any image does not have the date taken. You can choose Yes to ignore it or No to still change the filename.  Supported image will have ("T") at the end to indicate, that will not be included in the final filename.
4. **Preview**: Click "Preview" to see the new filename.
5. **Apply Changes**: Click "Apply name" to confirm the adjustments.


## III. Geotag and Display image on map
 <span style="color:green" fontweight="bold">**Note**</span>
- This feature will generate new files with GPS data and place it in the _Geotagged folder in the parent directory.
- Supported geotag extensions: `.jpg`, `.jpeg`, `.tiff`, `.webp`, `.heic`.
- Display image on map feature is still not well optimized, it may consume a lot of memory when displaying a large number of images.

![Screenshot Description](/screenshot/geotag.png)
1. **Select Photos**: Choose all photos that you want to add GPS data.
2. **Drag and Drop**: Import them into the program by dragging and dropping.
3. **Add GPS Data**: 
    - Use your right mouse to move the map, mouse wheel to zoom in and out to determine the location. Or you can copy the latitude and longitude from any maps and paste it into the input box.
    - Click "Apply" to add GPS data to the image.
    - The first image of the list will be displayed on the map.
4. **Additionally**: 
    - Type the name of current place and click "Save" to save the location to the list. You can use the "Remove" button to remove it.
    - Click < or > to navigate between saved locations.
    - You can change map type by clicking on the small map icon, it will change between Google map, Google satellite, Bing map, and Bing satellite.
5. **Display Image on Map**: Clear the list, click "Display images" then drag and drop geotagged images into the program to display them on the map.
![Screenshot Description](/screenshot/display.png)



# License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

