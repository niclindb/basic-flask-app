run the setupfile.sh script with sudo to deploy the app

make sure your flask app has 
        
    if __name__ == "__main__":
        port = int(os.environ.get("PORT", 5000))
        app.run(host="0.0.0.0", port=port)
