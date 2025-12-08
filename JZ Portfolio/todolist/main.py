# Jordan's TO-DO List Application using CustomTkinter

# DEPENDENCIES:
import customtkinter 
from CTkMessagebox import CTkMessagebox


# window details
window = customtkinter.CTk()
customtkinter.set_appearance_mode("dark")
customtkinter.set_default_color_theme("blue")
window.title("TO-DO List")
window.geometry('700x400')


# title
title = customtkinter.CTkLabel(window,text="TO-DO List",font=customtkinter.CTkFont(size=20,weight="bold"))
title.pack(pady=5)

# Entry
input = customtkinter.CTkEntry(window,placeholder_text="New task")
input.pack(pady=10)

# clears tasks
def clear_Task():
    for widget in task_frame.winfo_children():
        widget.destroy()
    global row, column
    row = 0
    column = 0
    print('Tasks cleared')

# frame for tasks
task_frame = customtkinter.CTkFrame(window)
task_frame.pack(pady=10, fill='both', expand=True)

# variables for grid position
global row, column
row = 0
column = 0

# add task function
def add_Task():
    global row
    global column
    name = input.get().strip()
    # VALIDATION:
    if len(name) == 0:
        CTkMessagebox(title="Error",message="Please enter a task",icon="warning")
        print('No task entered')
        return
    if len(name) >= 50:
        CTkMessagebox(title="Error",message="Task is too long",icon="warning")
        print('Task is too long')
        return
    # Add task
    else:
        check_var = customtkinter.StringVar(value = 'off')
        if row <= 5:
            task = customtkinter.CTkCheckBox(task_frame, text = name, variable = check_var,
            onvalue = 'on', offvalue = 'off').grid(row=row, column=column, pady=10,padx =10, sticky='ew')
            row += 1
            print('Task added:', name)
            print('row',row)
        elif column >= 5:
            CTkMessagebox(title="Error",message="Task limit reached",icon="warning")
            print('Task limit reached')
            return
        else:
            column += 1
            row = 0
            task = customtkinter.CTkCheckBox(task_frame, text = name, variable = check_var,
            onvalue = 'on', offvalue = 'off').grid(row=row, column=column, pady=10,padx =10, sticky='ew')
            print('Task added:', name)
            print('row',row)
            print('column',column)


# submit and clear buttons
submit = customtkinter.CTkButton(window,text ='Submit',command=add_Task).pack(padx=20, pady = 1, side = 'left')
clear = customtkinter.CTkButton(window,text ='Clear',command=clear_Task).pack(padx=20,pady = 1, side = 'right')

# run the window
window.mainloop()