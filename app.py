import os
from flask import Flask, render_template 
from werkzeug.middleware.proxy_fix import ProxyFix

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_prefix=1)

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/hello")
def hello():
    return "<h1>hello</h1>"

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port)