# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

param ($UserName)

# I load some variables from variables.ps1
. C:\SessionRecording\Scripts\variables.ps1

$FfmpegProcess = $null  # Will store a pointer to the running FFmpeg process
$UserData = $null  # Will store a JSON object of C:\SessionRecording\Output\file.txt
$CurrentResolution = $null  # Will store the current display resolution

$Domain = ((gcim Win32_LoggedOnUser).Antecedent | Where-Object {$_.Name -eq $UserName} | Select-Object Domain -Unique).Domain

$User = New-Object System.Security.Principal.NTAccount($Domain, $UserName)
$Sid = $User.Translate([System.Security.Principal.SecurityIdentifier]).Value

$UserEnvVar = [ordered]@{}
New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
$RegKey = (Get-ItemProperty "HKU:\${sid}\Environment")
$RegKey.PSObject.Properties | ForEach-Object {
  $UserEnvVar.Add($_.Name, $_.Value)
}
Remove-PSDrive -Name HKU

$Metadata = @{
  StackName = $UserEnvVar.AppStream_Stack_Name;
  UserAccessMode = $UserEnvVar.AppStream_User_Access_Mode;
  SessionReservationDateTime = $UserEnvVar.AppStream_Session_Reservation_DateTime;
  UserName = $UserEnvVar.AppStream_UserName;
  SessionId = $UserEnvVar.AppStream_Session_ID;
  ImageArn = (Get-Item Env:AppStream_Image_Arn).Value;
  InstanceType = (Get-Item Env:AppStream_Instance_Type).Value;
  FleetName = (Get-Item Env:AppStream_Resource_Name).Value
}

$Content = $Metadata | ConvertTo-Json
Set-Content -Path C:\SessionRecording\Output\metadata.txt -Value $Content

$Date = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$Key = "$($BUCKET_PREFIX)$($Metadata.StackName)/$($Metadata.FleetName)/$($Metadata.SessionId)/$($Date)-metadata.txt"
Write-S3Object -BucketName $BUCKET_NAME -Key $Key -File C:\SessionRecording\Output\metadata.txt -Region $BUCKET_REGION -ProfileName appstream_machine_role

# This function starts FFmpeg and returns the Process object. I use the built-in gdigrad module to capture the screen. FFmpeg outputs a file named YYYY-MM-DD_HH-MM-SS-video.mp4 where the date is when FFmpeg starts recording.
function StartRecording {
  $Date = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
  $Arguments = "-f gdigrab -framerate $($FRAME_RATE) -t $($VIDEO_MAX_DURATION) -y -v 0 -i desktop -vcodec libx264 -pix_fmt yuv420p C:\SessionRecording\Output\$($Date)-video.mp4"

  $pinfo = New-Object System.Diagnostics.ProcessStartInfo
  $pinfo.FileName = "C:\SessionRecording\Bin\ffmpeg.exe"
  $pinfo.Arguments = $Arguments
  $pinfo.WindowStyle = "Hidden"
  $pinfo.UseShellExecute = $false
  $pinfo.WindowStyle = "Hidden"
  $pinfo.RedirectStandardInput = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $pinfo
  $p.Start()
  $p.PriorityClass = "REALTIME"
  $script:FfmpegProcess =  $p
}

# This function compares the previous display resolution with the current display resolution and returns True if they differ.
function ResolutionHasChanged {
  param($NewResolution)

  if ($script:CurrentResolution -eq $null) {
    return $False
  }

  # Put the variable into an array if the variable has a single line (one screen)
  if (($script:CurrentResolution | Measure-Object -Line).Lines -eq 1) {
    $Current = @($script:CurrentResolution)
  }
  else {
    $Current = $script:CurrentResolution.split('\n')
  }

  if (($NewResolution | Measure-Object -Line).Lines -eq 1) {
    $New = @($NewResolution)
  }
  else {
    $New = $NewResolution.split('\n')
  }

  # If the number of screens differs, return True. Otherwise, check if each screen resolution differs
  if ($Current.Count -ne $New.Count) {
    return $True
  }
  else {
    for ($i = 0; $i -lt $Current.Count; $i++) {
      if ($Current[$i] -ne $New[$i]) {
        return $True
      }
    }
  }

  return $False
}

# This function kills FFmpeg gracefully by simulating a "q" key press
function StopRecording {
  if ($script:FfmpegProcess -ne $null) {
    $script:FfmpegProcess.StandardInput.Write('q')
  }
}

# This function uploads video files to Amazon S3 and deletes them locally, unless the video is the output of a running FFmpeg  process. Video files are deleted once uploaded to Amazon S3. It returns True if all video files were uploaded and deleted.
function UploadVideoFileToS3 {
  $AllVideosUploaded = $True

  foreach ($Video in (Get-Item -Path C:\SessionRecording\Output\*.mp4)) {

    # I check if the video is being generated by a running FFmpeg process
    $CurrentVideo = $False
    foreach ($Process in (Get-WmiObject Win32_Process -Filter "name = 'ffmpeg.exe'" | Select-Object CommandLine)) {
      if ($Process.CommandLine -like "*$($Video.Name)") {
        $CurrentVideo = $True
        $AllVideosUploaded = $False
      }
    }

    # I upload and delete the video if it is not being generated by FFmpeg
    if ($CurrentVideo -eq $True) {
      Continue
    }
    try {
      $Key = "$($BUCKET_PREFIX)$($Metadata.StackName)/$($Metadata.FleetName)/$($Metadata.SessionId)/$($Video.Name)"
      Write-S3Object -BucketName $BUCKET_NAME -Key $Key -File "C:\SessionRecording\Output\$($Video.Name)" -Region $BUCKET_REGION -ProfileName appstream_machine_role -ErrorAction Stop
      Remove-Item "C:\SessionRecording\Output\$($Video.Name)" -ErrorAction Stop
    }
    catch {
      $AllVideosUploaded = $False
      Continue
    }
  }

  # I return True if there are no more pending videos to upload
  return $AllVideosUploaded
}

function SessionIsClosing {
   return (Test-Path C:\SessionRecording\Scripts\ended.txt)
}

function WaitUntilAllVideosAreUploaded {
  # I retry 5 times to upload the remaining videos
  for ($i=0; $i -lt 5; $i++) {
    if ((UploadVideoFileToS3) -eq $True) {
      Break
    }
    else {
      Start-Sleep -Seconds 1
    }
  }
}

while ($True) {

  if (!($FfmpegProcess) -or ($FfmpegProcess -and $FfmpegProcess.HasExited)) {
    StartRecording
  }
  
  $NewResolution = (Get-DisplayResolution) -replace $([char]0) | Where-Object { $_ -ne "" }
  if (ResolutionHasChanged -NewResolution $NewResolution) {
    StopRecording
  }
  $CurrentResolution = $NewResolution
  
  UploadVideoFileToS3
    
  if (SessionIsClosing) {
    StopRecording
    WaitUntilAllVideosAreUploaded
    Break
  }

  Start-Sleep -Seconds 1
}

while ($True) {
  try {
    Remove-Item C:\SessionRecording\Scripts\ended.txt -ErrorAction Stop
    Break
  }
  catch {
    # I retry if the file failed to delete because it is locked
    Start-Sleep -Seconds 1
    Continue
  }
}