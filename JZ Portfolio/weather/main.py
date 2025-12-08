# DEPENDENCIES:
import customtkinter 
import requests
from PIL import Image
from io import BytesIO
import time
from CTkMessagebox import CTkMessagebox

# window details
window = customtkinter.CTk()
customtkinter.set_appearance_mode("dark")
customtkinter.set_default_color_theme("blue")
window.title("Weather App")
window.geometry('700x400')

# API key
weather_api_key = "f3b3bd81abcfc4d4bbbcf274c041cfe1"   
weather_base_url = "https://api.openweathermap.org/data/2.5/weather"

# title
title = customtkinter.CTkLabel(window,text="Weather App",font=customtkinter.CTkFont(size=20,weight="bold"))
title.grid(row= 0,column = 0,pady=5)

# weather function
def weather():
    city = city_entry.get()
    weather_api = 'https://api.openweathermap.org/data/2.5/weather?q='+ city +'&appid={f3b3bd81abcfc4d4bbbcf274c041cfe1}'
    json_data = requests.get(weather_api).json()
    condition = json_data['weather'][0]['main']
    temperature = int(json_data['main']['temp'] - 273.15)
    min_temperature = int(json_data['main']['temp_min'] - 273.15)
    max_temperature = int(json_data['main']['temp_max'] - 273.15)
    pressure = json_data['main']['pressure']
    humidity = json_data['main']['humidity']
    wind = json_data['wind']['speed']
    sunrise = time.strftime('%I:%M:%S', time.gmtime(json_data['sys']['sunrise'] + 3600))
    sunset = time.strftime('%I:%M:%S', time.gmtime(json_data['sys']['sunset'] + 3600))

# input box
city_entry = customtkinter.CTkEntry(window,placeholder_text="Enter City Name",width=200,height=30,font=customtkinter.CTkFont(size=15))
city_entry.pack(pady=20)

# submit button
