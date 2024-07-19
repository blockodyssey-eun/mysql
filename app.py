from flask import Flask, request, render_template, redirect, url_for, flash, jsonify, Response
import os
import subprocess
import psycopg2
import logging
import time

app = Flask(__name__)
app.secret_key = 'your_secret_key'
UPLOAD_FOLDER = 'uploads'
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER

if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)

# 로깅 설정
logging.basicConfig(filename='migration.log', level=logging.INFO, 
                    format='%(asctime)s - %(levelname)s - %(message)s')

@app.route('/', methods=['GET', 'POST'])
def index():
    return render_template('index.html')

@app.route('/connect', methods=['POST'])
def connect():
    host = request.form['POSTGRES_HOST']
    port = request.form['POSTGRES_PORT']
    user = request.form['POSTGRES_USER']
    password = request.form['POSTGRES_PASSWORD']
    database = request.form['POSTGRES_DB']  
    print(host, port, user, password, database)
    try:
        conn = psycopg2.connect(
            host=host,
            port=int(port),
            user=user,
            password=password,
            database=database  
        )
        conn.close()
        return jsonify(success=True, message="PostgreSQL 연결 성공!")
    except Exception as e:
        return jsonify(success=False, message=f"PostgreSQL 연결 실패: {str(e)}")

@app.route('/migrate', methods=['POST'])
def migrate():
    if 'file' not in request.files:
        flash('No file part')
        return redirect(url_for('index'))
    file = request.files['file']
    if file.filename == '':
        flash('No selected file')
        return redirect(url_for('index'))
    if file and file.filename.endswith('.sql'):
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], file.filename)
        file.save(filepath)
        db_name = os.path.splitext(file.filename)[0].replace('_dumps', '')
        
        # PostgreSQL 설정 값 가져오기 (오류 처리 추가)
        postgres_config = {}
        for key in ['POSTGRES_HOST', 'POSTGRES_PORT', 'POSTGRES_USER', 'POSTGRES_PASSWORD', 'POSTGRES_DB']:
            postgres_config[key] = request.form.get(key)
            if postgres_config[key] is None:
                flash(f'Missing {key} in form data')
                return redirect(url_for('index'))
        
        return Response(migrate_database(filepath, db_name, postgres_config), content_type='text/event-stream')
    else:
        flash('Invalid file format. Please upload a .sql file.')
        return redirect(url_for('index'))

def migrate_database(filepath, db_name, postgres_config):
    def generate():
        command = [
            './scripts/migrate.sh', 
            filepath,
            postgres_config['POSTGRES_HOST'],
            postgres_config['POSTGRES_PORT'],
            postgres_config['POSTGRES_USER'],
            postgres_config['POSTGRES_PASSWORD'],
            postgres_config['POSTGRES_DB']
        ]
        process = subprocess.Popen(command, 
                                   stdout=subprocess.PIPE, 
                                   stderr=subprocess.STDOUT,
                                   universal_newlines=True)
        
        for line in iter(process.stdout.readline, ''):
            yield f"{line}\n\n"
            time.sleep(0.1)
        
        process.stdout.close()
        return_code = process.wait()
        if return_code == 0:
            yield f"data: Migration completed for {db_name}\n\n"
        else:
            yield f"data: Migration failed for {db_name}\n\n"

    return generate()

if __name__ == '__main__':
    app.run(debug=True)