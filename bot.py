import os
import telebot
import requests
from flask import Flask
from threading import Thread

# Render-এর Environment Variable থেকে টোকেন ও কি নেওয়া
BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
BYNARA_API_KEY = os.getenv("BYNARA_API_KEY")
# আপনি চাইলে মডেলের নাম Render থেকে সেট করতে পারেন, না হলে ডিফল্ট হিসেবে এটি থাকবে
BYNARA_MODEL = os.getenv("BYNARA_MODEL", "আপনার_সঠিক_মডেলের_নাম_দিন") 

bot = telebot.TeleBot(BOT_TOKEN)
flask_app = Flask(__name__)

# Render হোস্টিং সচল রাখার জন্য একটি ডামি রুট
@flask_app.route('/')
def home():
    return "Bot is Running with Bynara API!"

def run_flask():
    flask_app.run(host="0.0.0.0", port=8080)

# টেলিগ্রাম মেসেজ হ্যান্ডলার
@bot.message_handler(func=lambda message: True)
def reply_to_user(message):
    user_text = message.text
    
    # Bynara API-এর URL এবং Headers
    url = "https://router.bynara.id/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {BYNARA_API_KEY}",
        "Content-Type": "application/json"
    }
    
    # Bynara-এর জন্য ডেটা পেলোড (যা আমরা আগেই টেস্ট করেছিলাম)
    payload = {
        "model": BYNARA_MODEL,
        "messages": [
            {"role": "user", "content": user_text}
        ]
    }
    
    try:
        # API-তে রিকোয়েস্ট পাঠানো
        response = requests.post(url, headers=headers, json=payload)
        
        if response.status_code == 200:
            result = response.json()
            bot_reply = result["choices"][0]["message"]["content"]
            bot.reply_to(message, bot_reply)
        else:
            # Error 403 বা 404 আসলে টেলিগ্রামেই দেখতে পাবেন
            bot.reply_to(message, f"এআই সার্ভার এরর: {response.status_code}")
    except Exception as e:
        bot.reply_to(message, "কোথাও কোনো সমস্যা হয়েছে। আবার চেষ্টা করুন।")

if __name__ == "__main__":
    # ব্যাকগ্রাউন্ডে ফ্ল্যাস্ক সার্ভার চালু করা (Render-এর জন্য)
    Thread(target=run_flask).start()
    
    print("Bot is polling with Bynara API...")
    bot.infinity_polling()
