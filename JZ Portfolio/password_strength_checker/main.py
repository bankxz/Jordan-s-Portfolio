# Jordan's Password Strength Checker using CustomTkinter

# DEPENDENCIES:
import customtkinter 
from CTkMessagebox import CTkMessagebox
import re


# window details
window = customtkinter.CTk()
customtkinter.set_appearance_mode("dark")
customtkinter.set_default_color_theme("blue")
window.title("Password Strength Checker")
window.geometry('700x400')

# password checker function
def password_strcheck():
    rating = 0
    password = psw_entry.get()
    password = password.strip()

    # Password strength rating system

    if len(password) <= 5:
        return CTkMessagebox(window,message = 'Unsuitable password length', icon = 'cancel', font =('Helvetica',15))
        
    if len(password) <= 8 and len(password) >5:
        rating -= 1
    else:
        rating += 1
    if len(password) >= 12:
        rating += 2
    for char in password:
        if char.isupper():
            rating += 3
            break
    for char in password:
        if char.islower():
            rating += 1
            break
    for char in password:
        if char.isdigit():
            rating += 2
            break
    counter = 0
    for char in password:
        if char in '@!#$%^&':
            rating += 3
            counter += 1
        if counter == 3:
            break
            
    if password.lower() == 'password':
        rating = 0
    

    # Use rating to decide how good your password is
    if rating <= 0:
        CTkMessagebox(window,message = 'Failed the test - Password is VERY WEAK', icon = 'cancel')
        print('Rating:', rating)
    if rating >0 and rating <= 3:
        CTkMessagebox(window,message = 'Failed the test - Password is WEAK', icon = 'cancel')
        print('Rating:', rating)
    if rating >=4 and rating <=6:
        CTkMessagebox(window,message = 'Passed the test - Password is MODERATE', icon = 'warning')
        print('Rating:', rating)
    if rating >=7 and rating <=9:
        CTkMessagebox(window,message = 'Passed the test - Password is STRONG', icon = 'check')
        print('Rating:', rating)
    if rating >=10:
        CTkMessagebox(window,message = 'Passed the test - Password is VERY STRONG', icon = 'check')
        print('Rating:', rating)

    


# title
title = customtkinter.CTkLabel(window,text="Password Strength Checker",font=customtkinter.CTkFont(size=20,weight="bold"))
title.pack(pady=40)

psw_entry = customtkinter.CTkEntry(window, placeholder_text="Enter your password below to check its strength...", font=customtkinter.CTkFont(size=14), width =350 )
psw_entry.pack(padx=10)

submit_button = customtkinter.CTkButton(window, text="Check Password Strength", font=('Helvetica',14), command = password_strcheck).pack(pady=20)
# run the window
window.mainloop()