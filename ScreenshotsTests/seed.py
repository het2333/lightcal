import json, urllib.request
from datetime import date
base='http://127.0.0.1:18018/v6';today=date.today().isoformat()
def post(path,payload):
 req=urllib.request.Request(base+path,data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'},method='POST')
 with urllib.request.urlopen(req) as r:return json.load(r)
def food(n,k,p,c,f,fi,ss):return {'name':n,'date':today,'calories':k,'protein':p,'carbs':c,'fat':f,'fiber':fi,'sugar':0,'sodium':50,'serving_size':ss,'nutrition_source':'screenshot_demo'}
post('/food-log',{'date':today,'meal_category':'breakfast','group_title':'早餐 · 燕麦与鸡蛋','request_id':'demo-breakfast','foods':[food('燕麦粥',180,6,31,4,3,'约1碗（200克）'),food('水煮鸡蛋',144,12,1,10,0,'2个（100克）')]})
post('/food-log',{'date':today,'meal_category':'lunch','group_title':'午餐 · 均衡轻食','request_id':'demo-lunch','foods':[food('熟米饭',232,5,50,1,1,'200克'),food('烤鸡胸肉',198,37,0,4,0,'120克'),food('清炒西兰花',65,4,7,3,3,'150克')]})
post('/hydration',{'date':today,'drink_type':'water','name':'水','amount_ml':350,'request_id':'demo-water-1'})
post('/hydration',{'date':today,'drink_type':'water','name':'水','amount_ml':250,'request_id':'demo-water-2'})
print('Seeded fictional demo data.')
