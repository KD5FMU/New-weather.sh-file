# New-weather.sh-file
This is the latest weather.sh file, Updated by Mike Webb WG5EEK and Paul Aidukas KN2R
### Novenber 27th, 2025 ###
First things first

#### Lets Change our directory to the correct location ####
```
cd /usr/local/sbin/supermon
```

#### let's backup the exisitng weather.sh file just to be on the safe side ####
```
sudo mv /usr/local/sbin/supermon/weather.sh /usr/local/sbin/supermon/weather.sh.bak
```

#### Download the new file ####
```
sudo wget https://raw.githubusercontent.com/KD5FMU/New-weather.sh-file/refs/heads/main/weather.sh
```
#### Now you can configure the weather info ####
This new scrupt file works with overseas Airport ICAO codes.
For Supermon 7.4 weather information chage the weather.sh file in the /var/www/html/supermon/global.inc
⭐️
This is where you will chage the Zip Code or Airport code
⭐️
![global-inc](https://github.com/KD5FMU/New-weather.sh-file/blob/main/global-inc.png)

Now you can do a 
```
sudo nano /usr/local/sbin/supermon/weather.sh
```
And customize what you want to see on the Supermon 7.4 page.
⭐️

![Logo](https://github.com/KD5FMU/New-weather.sh-file/blob/main/weather-sh-file.png)


