# رفع واصل إلى Google Play — خطوة بخطوة

الحزمة الجاهزة: `WASSEL-2.3.0-play.aab` (41 ميجا) موقّعة بمفتاح الرفع.
`com.alielhassan.wassel` · versionCode 4 · versionName 2.3.0 · minSdk 24 · targetSdk 36

## ١) إنشاء التطبيق
Play Console ← **Create app**: الاسم «واصل — توصيل سوق السودان الكبير»، اللغة العربية،
نوعه **App**، **Free**، وأقرّ بإقرارات المطوّر.

## ٢) نموذج «أمان البيانات» (Data safety) — أجب بهذه القيم
| السؤال | الجواب |
| --- | --- |
| Does your app collect or share data? | **Yes** |
| Data types | Location → **Approximate & precise location** (App functionality, not shared) · Personal info → **Name, Phone number, Address** · Photos → **Photos** (on-device only, not collected) |
| Is data encrypted in transit? | **Yes** |
| Can users request deletion? | **Yes** — عبر صفحة المطوّر، ويُنفَّذ خلال ٣٠ يوماً |
| Data shared with third parties | **No** (Supabase معالج بيانات، لا مشاركة تسويقية) |
| Ads / analytics | **No ads, no analytics SDKs** |

## ٣) سياسة الخصوصية
https://elhassanali36-art.github.io/Wassel-APK/privacy/

## ٤) مبرّرات الأذونات (Permission declarations)
- **ACCESS_FINE_LOCATION / ACCESS_COARSE_LOCATION**: «نعرض للسائق الطلبات القريبة منه ونحسب مسافة
  التوصيل. الموقع يُقرأ فقط أثناء فتح التطبيق، ولا يوجد تتبّع في الخلفية.»
- **CAMERA**: «تصوير رخصة القيادة والصورة الشخصية للتحقق من هوية السائق.»
- **READ/WRITE_EXTERNAL_STORAGE**: «اختيار صورة الرخصة من ملفات الجهاز وحفظ نسخة احتياطية من الطلبات.»
- **VIBRATE**: «تنبيه السائق عند وصول طلب جديد.»

## ٥) بيانات المتجر (Store listing)
**الاسم (30 حرفاً):** واصل — توصيل سوق السودان الكبير

**الوصف القصير (80 حرفاً):**
توصيل سريع من المتاجر والصيدليات والمطاعم — سعر عادل وتتبّع لحظي للطلب.

**الوصف الكامل:**
واصل شبكة توصيل تجمع المتاجر والصيدليات والمطاعم في سوق واحد، وتوصل الطلبات إلى العميل بأسرع
وقت وبسعر واضح محسوب بالمسافة.

للسائق:
• استلم الطلبات القريبة منك فقط، والأقرب أولاً.
• سعر التوصيل محسوب بالكيلومتر (سعر الكيلومتر + معامل الطريق) قبل أن تقبل.
• أقصى ٣ طلبات في يدك في وقت واحد، وسجل كامل لأرباحك.
• تحقق من الرخصة داخل التطبيق بصورتين، بلا أوراق.
• يعمل التطبيق بلا إنترنت، ويزامن الطلبات عند عودة الشبكة.

للمتجر:
• انشر الطلب من نظامك ويظهر لكل السائقين المتاحين.
• تابع حالة الطلب لحظة بلحظة حتى التسليم.

**التصنيف:** Maps & Navigation (أو Business)
**البريد الإلكتروني للدعم:** ضعه هنا (مطلوب من Google، ويظهر للعامة).
**الرسوم:** مجاني بلا مشتريات داخل التطبيق.

## ٦) المرئيات
- الأيقونة: `store/assets/icon-512.png` (512×512)
- صورة العرض: `store/assets/feature-1024x500.png` (1024×500)
- لقطات الشاشة: من ٢ إلى ٨ صور من الهاتف، عرض ١٠٨٠×١٩٢٠. خذها من التطبيق: الشاشة الرئيسية،
  قائمة الطلبات مع المسافة والسعر، ملف السائق، أرباحي.

## ٧) الاختبار المغلق (إلزامي للحساب الشخصي)
Testing ← **Closed testing** ← Create track ← ارفع الحزمة ← أضف **١٢ مختبِراً** ببريد Gmail ←
شارك رابط الانضمام ← يبقى الاختبار **١٤ يوماً** متواصلة ← بعدها يُفتح طلب **Production**.

## ٨) الرفع
Testing ← Closed testing ← Create new release ← ارفع `WASSEL-2.3.0-play.aab` ← Release notes:
«الإصدار الأول» ← Review release ← Start rollout.

## ملاحظات مهمة
- مفتاح الرفع محفوظ في `/opt/wassel-app/wassel.keystore` (alias: `wassel`). **احتفظ بنسخة منه**؛
  بدونه لا تستطيع تحديث التطبيق بعد النشر، إلا عبر خدمة Play App Signing.
- بعد النشر لا يمكن تغيير اسم الحزمة `com.alielhassan.wassel` أبداً.
- كل تحديث لاحق يحتاج versionCode أعلى من ٤.
