from flask import Flask, request, render_template, redirect, url_for, flash
import os
import subprocess

app = Flask(__name__)
app.secret_key = 'your_secret_key'
UPLOAD_FOLDER = 'uploads'
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER

if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)

@app.route('/', methods=['GET', 'POST'])
def index():
    if request.method == 'POST':
        env_vars = {
            'MYSQL_ROOT_PASSWORD': request.form['MYSQL_ROOT_PASSWORD'],
            'MYSQL_PORT': request.form['MYSQL_PORT'],
            'POSTGRES_HOST': request.form['POSTGRES_HOST'],
            'POSTGRES_PORT': request.form['POSTGRES_PORT'],
            'POSTGRES_USER': request.form['POSTGRES_USER'],
            'POSTGRES_PASSWORD': request.form['POSTGRES_PASSWORD'],
            'DATA_PATH_HOST': request.form['DATA_PATH_HOST'],
        }
        save_env_vars(env_vars)
        update_docker_compose(env_vars)
        update_migrate_sh(env_vars)
        flash('환경 변수가 저장되었습니다.')
    return render_template('index.html')

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
        result = migrate_database(filepath, db_name)
        return render_template('index.html', log=result)
    else:
        flash('Invalid file format. Please upload a .sql file.')
        return redirect(url_for('index'))

def save_env_vars(env_vars):
    with open('.env', 'w') as f:
        for key, value in env_vars.items():
            f.write(f'{key}={value}\n')

def update_docker_compose(env_vars):
    with open('docker-compose.yml', 'r') as f:
        compose_content = f.read()
    for key, value in env_vars.items():
        compose_content = compose_content.replace(f'${{{key}}}', value)
    with open('docker-compose.yml', 'w') as f:
        f.write(compose_content)

def update_migrate_sh(env_vars):
    with open('scripts/migrate.sh', 'r') as f:
        migrate_content = f.read()
    for key, value in env_vars.items():
        migrate_content = migrate_content.replace(f'${{{key}}}', value)
    with open('scripts/migrate.sh', 'w') as f:
        f.write(migrate_content)

def migrate_database(filepath, db_name):
    try:
        result = subprocess.run(['./scripts/migrate.sh', filepath], capture_output=True, text=True)
        if result.returncode != 0:
            return f"Migration failed for {db_name}: {result.stderr}"
        return f"Migration completed for {db_name}: {result.stdout}"
    except Exception as e:
        return f"An error occurred: {str(e)}"

if __name__ == '__main__':
    app.run(debug=True)