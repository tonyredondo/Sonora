#!/usr/bin/env python3
"""Create marked synthetic CUE/M3U/local-import fixtures on one iOS simulator."""
import argparse,os,shutil,subprocess
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('simulator')
args=parser.parse_args()
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.simulator,'com.tonyredondo.Sonora','data'],env=env,text=True).strip())
root=container/'Documents'/'Sonora Portable QA'
marker=root/'.sonora-portable-demo'
if root.exists() and not marker.exists():raise SystemExit('Refusing to overwrite unmarked folder: '+str(root))
(root/'Concierto').mkdir(parents=True,exist_ok=True)
marker.write_text('Synthetic Sonora CUE/M3U/offline QA fixtures. No user music.\n')
for path,title,duration in [('Concierto/Directo.flac','Concierto completo',16),('Canción suelta.flac','Canción suelta',16)]:
 subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',f'sine=frequency=330:sample_rate=44100:duration={duration}','-ac','2','-c:a','flac','-metadata','title='+title,'-metadata','artist=Sonora QA','-metadata','album=Portátiles',str(root/path)],check=True)
(root/'Concierto'/'Directo.cue').write_text('PERFORMER "Sonora QA"\nTITLE "Directo Sonora"\nFILE "Directo.flac" WAVE\nTRACK 01 AUDIO\nTITLE "Primer acto"\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nTITLE "Último acto"\nINDEX 01 00:08:00\n',encoding='utf-8')
(root/'Concierto'/'Directo.lrc').write_text('[00:01]Primer acto\n[00:09]Último acto\n',encoding='utf-8')
(root/'Ruta.m3u8').write_text('#EXTM3U\n#EXTINF:8,Último acto\n#EXTVLCOPT:start-time=8.000000\nConcierto/Directo.flac\n#EXTINF:16,Canción suelta\nCanción suelta.flac\n#EXTINF:8,Primer acto\n#EXTVLCOPT:start-time=0.000000\n#EXTVLCOPT:stop-time=8.000000\nConcierto/Directo.flac\n',encoding='utf-8')
(root/'Ruta incompleta.m3u').write_text('#EXTM3U\nmissing.mp3\nCanción suelta.flac\n',encoding='utf-8')
icon=Path(__file__).resolve().parents[1]/'Sonora'/'Assets.xcassets'/'AppIcon.appiconset'/'AppIcon.png'
for folder in [root,root/'Concierto']:shutil.copyfile(icon,folder/'cover.png')
print(root)
