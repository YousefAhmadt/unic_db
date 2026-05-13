import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:postgres/postgres.dart';
import 'data/setData';
import 'data/databaseService';

// import 'ai/geminiApiService';
// import 'package:http/http.dart' as http;

import 'student/dashboard_student';

class CourseServer {
  final db = DatabaseService();
  late Connection connection;

  Future<void> connectToDatabase() async {
    connection = await db.createConnection();
  }

  // =========================
  // Helpers
  // =========================
  double parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  int parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  List<String> parseStringList(dynamic value) {
    if (value == null) return [];
    if (value is List) return value.map((e) => e.toString()).toList();
    return [];
  }

  // =========================
  // 1. Weighted Prerequisites Score
  // الـ prerequisite المباشر (الأخير) أهم من السابق
  // =========================
  double weightedPrereqScore({
    required String courseId,
    required Map<String, double> grades,
    required Map<String, List<String>> relations,
  }) {
    if (!relations.containsKey(courseId)) return 2.5;

    final prereqs = relations[courseId]!;
    double weightedSum = 0;
    double totalWeight = 0;
    double weight = prereqs.length.toDouble();

    for (final prereqId in prereqs) {
      if (grades.containsKey(prereqId)) {
        weightedSum += grades[prereqId]! * weight;
        totalWeight += weight;
      }
      weight--;
    }

    return totalWeight > 0 ? (weightedSum / totalWeight) : 2.5;
  }

  // =========================
  // 2. GPA Trend
  // هل الطالب بتحسن أو بتراجع عبر الزمن
  // =========================
  double calculateGpaTrend(Map<String, double> grades) {
    if (grades.length < 2) return 0.0;

    final values = grades.values.toList();
    double totalChange = 0;

    for (int i = 1; i < values.length; i++) {
      totalChange += values[i] - values[i - 1];
    }

    // متوسط التغيير لكل مادة
    return totalChange / (values.length - 1);
  }

  Router get router {
    final router = Router();

    // =========================
    // Setup
    // =========================
    router.post('/api/setup-database', (Request request) async {
      try {
        final setupDatabase = SetupDatabase(connection);
        // FIX: أضفنا await على كلا الاستدعاءين
        await setupDatabase.createSchema();
        final userCheck = await connection.execute(
          'SELECT count(*) FROM users',
        );
        if (userCheck.first[0] == 0) {
          await setupDatabase.seedData();
        }
        return Response.ok(
          jsonEncode({'message': 'System setup successful'}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Add User
    // =========================
    router.post('/api/admin/add-user', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());

        await connection.execute(
          Sql.named(
            'INSERT INTO users (id, name, email, password, role) VALUES (@id, @n, @e, @p, @r)',
          ),
          parameters: {
            'id': p['id'],
            'n': p['name'],
            'e': p['email'],
            'p': p['password'],
            'r': p['role'],
          },
        );

        if (p['role'] == 'student') {
          final result = await connection.execute(
            Sql.named('SELECT total_credits FROM majors WHERE id = @id'),
            parameters: {'id': p['major_id'] ?? 1},
          );

          if (result.isEmpty) throw Exception('Major not found');

          final earned = parseInt(p['earned_credits'] ?? 0);
          // FIX: total_credits = الإجمالي من التخصص، مش الباقي
          final totalFromMajor = parseInt(
            result.first.toColumnMap()['total_credits'],
          );

          await connection.execute(
            Sql.named('''
              INSERT INTO student_stats
                (student_id, gpa, earned_credits, total_credits, major_id)
              VALUES (@id, @gpa, @earned, @total, @major_id)
            '''),
            parameters: {
              'id': p['id'],
              'gpa': parseDouble(p['gpa'] ?? 0.0),
              'earned': earned,
              'total': totalFromMajor, // FIX: كان remainingCredits خطأ
              'major_id': p['major_id'] ?? 1,
            },
          );
        }

        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Add Course
    // FIX: حذفنا عمود major من INSERT (مش موجود)
    //      وأضفنا INSERT في course_majors بعدها
    // =========================
    router.post('/api/admin/add-course', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());

        await connection.execute(
          Sql.named(
            'INSERT INTO courses (id, title, credits, prerequisites, core) VALUES (@id, @t, @c, @pre, @core)',
          ),
          parameters: {
            'id': p['id'],
            't': p['title'],
            'c': p['credits'],
            'pre': p['prerequisites'] ?? [],
            'core': p['core'] ?? 'elective',
          },
        );

        // ربط المادة بالتخصص في course_majors
        if (p['major_id'] != null) {
          await connection.execute(
            Sql.named(
              'INSERT INTO course_majors (course_id, major_id) VALUES (@cid, @mid)',
            ),
            parameters: {'cid': p['id'], 'mid': p['major_id']},
          );
        }

        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Add Major
    // =========================
    router.post('/api/admin/add-major', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());
        await connection.execute(
          Sql.named('''
    INSERT INTO majors (name, total_credits)
    VALUES (@n, @c)
    ON CONFLICT (name) DO UPDATE SET
      total_credits = EXCLUDED.total_credits
  '''),
          parameters: {'n': p['name'], 'c': p['total_credits']},
        );
        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        print('ADD MAJOR ERROR: $e');
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Add to Degree Plan
    // =========================
    router.post('/api/admin/add-to-degree-plan', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());

        // ✅ check course
        final courseCheck = await connection.execute(
          Sql.named('SELECT id FROM courses WHERE id = @cid'),
          parameters: {'cid': p['course_id']},
        );

        if (courseCheck.isEmpty) {
          return Response(
            400,
            body: jsonEncode({'error': 'Course not found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // ✅ check major
        final majorCheck = await connection.execute(
          Sql.named('SELECT id FROM majors WHERE id = @mid'),
          parameters: {'mid': p['major_id']},
        );

        if (majorCheck.isEmpty) {
          return Response(
            400,
            body: jsonEncode({'error': 'Major not found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // ✅ insert
        await connection.execute(
          Sql.named('''
        INSERT INTO degree_plans 
        (major_id, course_id, semester_number, is_mandatory)
        VALUES (@mid, @cid, @sn, @im)
      '''),
          parameters: {
            'mid': p['major_id'],
            'cid': p['course_id'],
            'sn': p['semester_number'],
            'im': p['is_mandatory'],
          },
        );

        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        print('ADD TO DEGREE PLAN ERROR: $e');
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Add Announcement
    // =========================
    router.post('/api/admin/add-announcement', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());
        await connection.execute(
          Sql.named(
            'INSERT INTO announcements (title, content) VALUES (@t, @c)',
          ),
          parameters: {'t': p['title'], 'c': p['content']},
        );
        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Update User
    // FIX: الآن يقبل role من الـ request بدل ما يتجاهلها
    // =========================
    router.post('/api/admin/update-user', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());
        final id = p['id'];
        final name = p['name'];

        if (id == null || name == null) {
          return Response(
            400,
            body: jsonEncode({'error': 'id and name required'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final userResult = await connection.execute(
          Sql.named('SELECT role FROM users WHERE id = @id'),
          parameters: {'id': id},
        );

        if (userResult.isEmpty) {
          return Response(
            404,
            body: jsonEncode({'error': 'User not found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // FIX: نقبل role من الـ request إذا موجود، وإلا نبقى على الحالي
        final currentRole = userResult.first.toColumnMap()['role'];
        final newRole = p['role'] ?? currentRole;

        await connection.execute(
          Sql.named('UPDATE users SET name = @n, role = @r WHERE id = @id'),
          parameters: {'id': id, 'n': name, 'r': newRole},
        );

        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Delete User
    // =========================
    router.post('/api/admin/delete-user', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());
        await connection.execute(
          Sql.named('DELETE FROM users WHERE id = @id'),
          parameters: {'id': p['id']},
        );
        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Update Course
    // =========================
    router.post('/api/admin/update-course', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());
        await connection.execute(
          Sql.named(
            'UPDATE courses SET title = @t, credits = @c WHERE id = @id',
          ),
          parameters: {'id': p['id'], 't': p['title'], 'c': p['credits']},
        );
        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Delete Course
    // =========================
    router.post('/api/admin/delete-course', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());
        await connection.execute(
          Sql.named('DELETE FROM courses WHERE id = @id'),
          parameters: {'id': p['id']},
        );
        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Delete Announcement
    // =========================
    router.post('/api/admin/delete-announcement', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());
        await connection.execute(
          Sql.named('DELETE FROM announcements WHERE id = @id'),
          parameters: {'id': p['id']},
        );
        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Stats
    // =========================
    router.get('/api/admin/stats', (Request request) async {
      try {
        final usersCount = await connection.execute(
          'SELECT count(*) FROM users',
        );
        final studentsCount = await connection.execute(
          "SELECT count(*) FROM users WHERE role = 'student'",
        );
        final coursesCount = await connection.execute(
          'SELECT count(*) FROM courses',
        );
        final majorsCount = await connection.execute(
          'SELECT count(*) FROM majors',
        );
        final announcementsCount = await connection.execute(
          'SELECT count(*) FROM announcements',
        );

        return Response.ok(
          jsonEncode({
            'totalUsers': usersCount.first[0],
            'totalStudents': studentsCount.first[0],
            'totalCourses': coursesCount.first[0],
            'totalMajors': majorsCount.first[0],
            'totalAnnouncements': announcementsCount.first[0],
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e, stack) {
        print('STATS ERROR: $e\n$stack');
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Admin: Get All Users
    // =========================
    router.get('/api/admin/users', (Request request) async {
      try {
        final res = await connection.execute(
          'SELECT id, name, email, role FROM users',
        );
        return Response.ok(
          jsonEncode(res.map((r) => r.toColumnMap()).toList()),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Login
    // =========================
    router.post('/api/login', (Request request) async {
      try {
        final payload = jsonDecode(await request.readAsString());
        final result = await connection.execute(
          Sql.named(
            'SELECT * FROM users WHERE email = @email AND password = @password',
          ),
          parameters: {
            'email': payload['email'],
            'password': payload['password'],
          },
        );
        if (result.isEmpty) {
          return Response.forbidden(
            jsonEncode({'error': 'Unauthorized'}),
            headers: {'Content-Type': 'application/json'},
          );
        }
        return Response.ok(
          jsonEncode(result.first.toColumnMap()),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Courses (GET)
    // =========================
    router.get('/api/student/courses', (Request request) async {
      try {
        final studentId = request.url.queryParameters['student_id'];

        if (studentId == null || studentId.isEmpty) {
          return Response(
            400,
            body: jsonEncode({'error': 'student_id is required'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final result = await connection.execute(
          Sql.named('''
        SELECT
          c.id,
          c.title,
          c.description,
          c.credits,
          c.prerequisites,

          CASE
            WHEN NOT EXISTS (
              SELECT 1
              FROM unnest(c.prerequisites) AS pre(course_id)
              WHERE NOT EXISTS (
                SELECT 1
                FROM student_course_status scs2
                WHERE scs2.student_id = ss.student_id
                  AND scs2.course_id = pre.course_id
                  AND scs2.is_completed = true
              )
            )
            THEN true
            ELSE false
          END AS can_register,

          COALESCE(
            (
              SELECT json_agg(pre.course_id)
              FROM unnest(c.prerequisites) AS pre(course_id)
              WHERE NOT EXISTS (
                SELECT 1
                FROM student_course_status scs2
                WHERE scs2.student_id = ss.student_id
                  AND scs2.course_id = pre.course_id
                  AND scs2.is_completed = true
              )
            ),
            '[]'
          ) AS missing_prerequisites,

          COALESCE(cr.requirement_type, c.requirement_type) AS requirement_type,

          COALESCE(
            json_agg(
              DISTINCT jsonb_build_object(
                'section', x.section,
                'days', x.days,
                'start_time', x.start_time,
                'end_time', x.end_time,
                'room', x.room,
                'professor_id', x.professor_id,
                'professor_name', x.professor_name
              )
            ) FILTER (WHERE x.section IS NOT NULL),
            '[]'
          ) AS schedule_options

        FROM student_stats ss

        JOIN course_requirements cr
          ON cr.major_id = ss.major_id

        JOIN courses c
          ON c.id = cr.course_id

        JOIN semesters sem
          ON sem.is_active = true

        JOIN course_schedules active_cs
          ON active_cs.course_id = c.id
         AND active_cs.semester_id = sem.id

        LEFT JOIN LATERAL (
          SELECT
            cs.section,
            json_agg(
              cs.day
              ORDER BY CASE cs.day
                WHEN 'Sunday' THEN 1
                WHEN 'Monday' THEN 2
                WHEN 'Tuesday' THEN 3
                WHEN 'Wednesday' THEN 4
                WHEN 'Thursday' THEN 5
                WHEN 'Friday' THEN 6
                WHEN 'Saturday' THEN 7
                ELSE 8
              END
            ) AS days,
            to_char(MIN(cs.start_time), 'HH24:MI') AS start_time,
            to_char(MIN(cs.end_time), 'HH24:MI') AS end_time,
            MIN(cs.room) AS room,
            MIN(cs.professor_id) AS professor_id,
            MIN(u.name) AS professor_name
          FROM course_schedules cs
          LEFT JOIN users u
            ON u.id = cs.professor_id
          WHERE cs.course_id = c.id
            AND cs.semester_id = sem.id
          GROUP BY cs.section
        ) x ON true

        WHERE ss.student_id = @studentId

          AND NOT EXISTS (
            SELECT 1
            FROM student_course_status scs
            WHERE scs.student_id = ss.student_id
              AND scs.course_id = c.id
              AND scs.is_completed = true
          )

        GROUP BY
          c.id,
          c.title,
          c.description,
          c.credits,
          c.prerequisites,
          ss.student_id,
          COALESCE(cr.requirement_type, c.requirement_type)

        ORDER BY c.id;
      '''),
          parameters: {'studentId': studentId},
        );

        return Response.ok(
          jsonEncode(result.map((r) => r.toColumnMap()).toList()),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e, stack) {
        print('CURRENT COURSES ERROR: $e\n$stack');

        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });
    // =========================
    // Majors (GET)
    // =========================
    router.get('/api/majors', (Request request) async {
      try {
        final res = await connection.execute('SELECT * FROM majors');
        return Response.ok(
          jsonEncode(res.map((r) => r.toColumnMap()).toList()),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Announcements (GET)
    // =========================
    router.get('/api/announcements', (Request request) async {
      try {
        final res = await connection.execute(
          'SELECT * FROM announcements ORDER BY created_at DESC',
        );
        final data = res.map((r) {
          final map = r.toColumnMap();
          return {
            ...map,
            'created_at': (map['created_at'] as DateTime?)?.toIso8601String(),
          };
        }).toList();
        return Response.ok(
          jsonEncode(data),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Student: Degree Plan
    // FIX: كان يستخدم m['semester'] والصح m['semester_number']
    // =========================
    router.get('/api/student/degree-plan', (Request req) async {
      try {
        final majorIdParam = req.url.queryParameters['major_id'];
        final studentId = req.url.queryParameters['student_id'];

        if (majorIdParam == null || studentId == null) {
          return Response(
            400,
            body: jsonEncode({'error': 'major_id & student_id required'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // جلب major_id من student_stats
        final majorRes = await connection.execute(
          Sql.named(
            'SELECT major_id FROM student_stats WHERE student_id = @sid',
          ),
          parameters: {'sid': studentId},
        );

        if (majorRes.isEmpty) {
          return Response(
            404,
            body: jsonEncode({'error': 'Student major not found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final majorId = parseInt(majorRes.first[0]);

        // خطة التخصص
        final planRes = await connection.execute(
          Sql.named('''
    SELECT DISTINCT ON (dp.course_id)
      dp.course_id,
      dp.semester_number,
      dp.is_mandatory,
      c.title AS course_name,
      COALESCE(cr.requirement_type, c.requirement_type) AS requirement_type,
      CASE 
        WHEN (
          SELECT COUNT(DISTINCT major_id) 
          FROM course_majors 
          WHERE course_id = dp.course_id
        ) > 1 THEN true 
        ELSE false 
      END AS is_shared
    FROM degree_plans dp
    JOIN courses c 
      ON c.id = dp.course_id
    LEFT JOIN course_requirements cr
      ON cr.course_id = dp.course_id
     AND cr.major_id = @mid
    WHERE dp.major_id = @mid
       OR (
         dp.course_id IN (
           SELECT course_id FROM course_majors WHERE major_id = @mid
         )
         AND dp.course_id IN (
           SELECT course_id FROM course_majors 
           GROUP BY course_id HAVING COUNT(DISTINCT major_id) > 1
         )
       )
    ORDER BY dp.course_id, dp.semester_number
  '''),
          parameters: {'mid': majorId},
        );
        // المواد المكتملة
        final doneRes = await connection.execute(
          Sql.named('''
            SELECT course_id
            FROM student_course_status
            WHERE student_id = @sid AND is_completed = true
          '''),
          parameters: {'sid': studentId},
        );

        final done = doneRes.map((e) => e[0].toString()).toSet();

        List completedCourses = [];
        List remainingCourses = [];

        for (final row in planRes) {
          final m = row.toColumnMap();
          final courseId = m['course_id'].toString();

          final entry = {
            'course_id': courseId,
            'semester': m['semester_number'],
            'is_mandatory': m['is_mandatory'],
            'is_shared': m['is_shared'],
            'name': m['course_name']?.toString() ?? 'Unknown Course',
            'requirement_type':
                m['requirement_type']?.toString() ?? 'major_required',
          };

          if (done.contains(courseId)) {
            completedCourses.add({...entry, 'status': 'completed'});
          } else {
            remainingCourses.add({...entry, 'status': 'remaining'});
          }
        }
        final progress = planRes.isEmpty
            ? 0.0
            : (completedCourses.length / planRes.length) * 100;

        return Response.ok(
          jsonEncode({
            'major_id': majorId,
            'student_id': studentId,
            'total_courses': planRes.length,
            'completed_count': completedCourses.length,
            'remaining_count': remainingCourses.length,
            'progress': progress.toStringAsFixed(1),
            'completed_courses': completedCourses,
            'remaining_courses': remainingCourses,
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e, stack) {
        print('DEGREE PLAN ERROR: $e\n$stack');
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Student: Degree Progress
    // =========================
    router.get('/api/student/degree-progress', (Request request) async {
      try {
        final studentId = request.url.queryParameters['student_id'];

        if (studentId == null) {
          return Response(
            400,
            body: jsonEncode({'error': 'student_id required'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final studentRes = await connection.execute(
          Sql.named(
            'SELECT major_id FROM student_stats WHERE student_id = @id',
          ),
          parameters: {'id': studentId},
        );

        if (studentRes.isEmpty) {
          return Response(
            404,
            body: jsonEncode({'error': 'Student not found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final majorId = studentRes.first[0];

        final planRes = await connection.execute(
          Sql.named('''
            SELECT course_id, is_mandatory, semester_number
            FROM degree_plans
            WHERE major_id = @mid
            ORDER BY semester_number
          '''),
          parameters: {'mid': majorId},
        );

        final planCourses = planRes.map((r) => r.toColumnMap()).toList();

        final completedRes = await connection.execute(
          Sql.named('''
            SELECT course_id
            FROM student_course_status
            WHERE student_id = @id AND is_completed = true
          '''),
          parameters: {'id': studentId},
        );

        final completed = completedRes.map((r) => r[0].toString()).toSet();

        List completedCourses = [];
        List remainingCourses = [];

        for (var c in planCourses) {
          final courseId = c['course_id'].toString();
          if (completed.contains(courseId)) {
            completedCourses.add(c);
          } else {
            remainingCourses.add(c);
          }
        }

        final total = planCourses.length;
        final done = completedCourses.length;
        final progress = total == 0 ? 0.0 : (done / total * 100);

        return Response.ok(
          jsonEncode({
            'total_courses': total,
            'completed_count': done,
            'remaining_count': remainingCourses.length,
            'progress_percent': progress.toStringAsFixed(1),
            'completed_courses': completedCourses,
            'remaining_courses': remainingCourses,
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // =========================
    // Student: Dashboard Stats
    // =========================
    router.get('/api/student/dashboard-stats', (Request request) async {
      try {
        final studentId = request.url.queryParameters['student_id'];
        if (studentId == null) {
          return Response(
            400,
            body: jsonEncode({'error': 'student_id is required'}),
            headers: {'Content-Type': 'application/json'},
          );
        }
        final d = await Dashboard_Stats(
          connection: connection,
        ).getDashboard(studentId.toString());

        return d;
      } catch (e, stack) {
        print('DASHBOARD ERROR: $e\n$stack');
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });
    // =========================
    // Course: Check Eligibility
    // FIX: استبدلنا academic_history (غير موجود) بـ student_course_status
    //      وحذفنا year_level (غير موجود في courses)
    // =========================
    router.get('/api/course/check-eligibility', (Request request) async {
      try {
        final studentId = request.url.queryParameters['student_id'];
        final courseId = request.url.queryParameters['course_id'];

        if (studentId == null || courseId == null) {
          return Response(
            400,
            body: jsonEncode({'error': 'Missing parameters'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // FIX: الجدول الصحيح هو student_course_status
        final completedRes = await connection.execute(
          Sql.named('''
            SELECT course_id
            FROM student_course_status
            WHERE student_id = @id AND is_completed = true
          '''),
          parameters: {'id': studentId},
        );

        final completed = completedRes.map((r) => r[0].toString()).toSet();

        // التحقق من وجود المادة
        final courseRes = await connection.execute(
          Sql.named('SELECT id, title FROM courses WHERE id = @id'),
          parameters: {'id': courseId},
        );

        if (courseRes.isEmpty) {
          return Response(
            404,
            body: jsonEncode({'error': 'Course not found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // prerequisites من course_prerequisites
        final prereqRes = await connection.execute(
          Sql.named('''
            SELECT prerequisite_id
            FROM course_prerequisites
            WHERE course_id = @id
          '''),
          parameters: {'id': courseId},
        );

        final prerequisites = prereqRes.map((r) => r[0].toString()).toList();
        final missing =
            prerequisites.where((p) => !completed.contains(p)).toList();
        final isEligible = missing.isEmpty;

        return Response.ok(
          jsonEncode({
            'eligible': isEligible,
            'missing_prerequisites': missing,
            'completed_prerequisites':
                prerequisites.where((p) => completed.contains(p)).toList(),
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });
    router.post('/api/admin/delete-major', (Request request) async {
      try {
        final p = jsonDecode(await request.readAsString());

        final majorId = p['id'];

        if (majorId == null) {
          return Response(
            400,
            body: jsonEncode({'error': 'id is required'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // تحقق إذا موجود
        final check = await connection.execute(
          Sql.named('SELECT id FROM majors WHERE id = @id'),
          parameters: {'id': majorId},
        );

        if (check.isEmpty) {
          return Response(
            404,
            body: jsonEncode({'error': 'Major not found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // حذف
        await connection.execute(
          Sql.named('DELETE FROM majors WHERE id = @id'),
          parameters: {'id': majorId},
        );

        return Response.ok(
          jsonEncode({'success': true}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        print('DELETE MAJOR ERROR: $e');
        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });
    router.post('/api/student/register-course', (Request request) async {
      try {
        final rawBody = await request.readAsString();
        final body = jsonDecode(rawBody);

        final studentId = body['student_id']?.toString();
        final registrations = body['registrations'];

        if (studentId == null ||
            studentId.isEmpty ||
            registrations == null ||
            registrations is! List ||
            registrations.isEmpty) {
          return Response(
            400,
            body: jsonEncode({
              'error': 'student_id and registrations are required',
            }),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final semRes = await connection.execute('''
      SELECT id
      FROM semesters
      WHERE is_active = true
      LIMIT 1;
    ''');

        if (semRes.isEmpty) {
          return Response(
            400,
            body: jsonEncode({'error': 'No active semester found'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final semesterId = int.parse(semRes.first[0].toString());

        final registeredCourses = [];
        final failedCourses = [];

        for (final item in registrations) {
          if (item is! Map) {
            failedCourses.add({
              'course_id': null,
              'section': null,
              'error': 'Invalid registration item',
            });
            continue;
          }

          final courseId = item['course_id']?.toString();
          final section = item['section']?.toString();

          if (courseId == null ||
              courseId.isEmpty ||
              section == null ||
              section.isEmpty) {
            failedCourses.add({
              'course_id': courseId,
              'section': section,
              'error': 'course_id and section are required',
            });
            continue;
          }

          final scheduleRes = await connection.execute(
            Sql.named('''
          SELECT 1
          FROM course_schedules
          WHERE course_id = @courseId
            AND section = @section
            AND semester_id = @semesterId
          LIMIT 1;
        '''),
            parameters: {
              'courseId': courseId,
              'section': section,
              'semesterId': semesterId,
            },
          );

          if (scheduleRes.isEmpty) {
            failedCourses.add({
              'course_id': courseId,
              'section': section,
              'error':
                  'This course section is not available in the active semester',
            });
            continue;
          }

          final completedRes = await connection.execute(
            Sql.named('''
          SELECT 1
          FROM student_course_status
          WHERE student_id = @studentId
            AND course_id = @courseId
            AND is_completed = true
          LIMIT 1;
        '''),
            parameters: {
              'studentId': studentId,
              'courseId': courseId,
            },
          );

          if (completedRes.isNotEmpty) {
            failedCourses.add({
              'course_id': courseId,
              'section': section,
              'error': 'Student already completed this course',
            });
            continue;
          }

          await connection.execute(
            Sql.named('''
          INSERT INTO registrations
          (student_id, course_id, section, semester_id, status)
          VALUES
          (@studentId, @courseId, @section, @semesterId, 'enrolled')
          ON CONFLICT (student_id, course_id, section, semester_id)
          DO NOTHING;
        '''),
            parameters: {
              'studentId': studentId,
              'courseId': courseId,
              'section': section,
              'semesterId': semesterId,
            },
          );

          registeredCourses.add({
            'course_id': courseId,
            'section': section,
            'semester_id': semesterId,
            'status': 'enrolled',
          });
        }

        return Response.ok(
          jsonEncode({
            'message': 'Registration process completed',
            'student_id': studentId,
            'semester_id': semesterId,
            'registered_courses': registeredCourses,
            'failed_courses': failedCourses,
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e, stack) {
        print('REGISTER COURSE ERROR: $e\n$stack');

        return Response(
          500,
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    router.get('/api/student/registered-courses', (Request request) async {
      try {
        final studentId = request.url.queryParameters['student_id'];

        if (studentId == null || studentId.isEmpty) {
          return Response(
            400,
            body: jsonEncode({
              'error': 'student_id is required',
            }),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // الفصل النشط
        final semRes = await connection.execute('''
      SELECT id
      FROM semesters
      WHERE is_active = true
      LIMIT 1;
    ''');

        if (semRes.isEmpty) {
          return Response(
            400,
            body: jsonEncode({
              'error': 'No active semester found',
            }),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final semesterId = int.parse(semRes.first[0].toString());

        // المواد المسجلة
        final result = await connection.execute(
          Sql.named('''
    SELECT 
      r.id,
      r.student_id,
      r.course_id,
      c.title AS course_title,
      r.section,
      r.semester_id,
      r.status,

      cs.day,
      cs.start_time,
      cs.end_time,
      cs.room

    FROM registrations r
    LEFT JOIN courses c 
      ON c.id = r.course_id
    LEFT JOIN course_schedules cs
      ON cs.course_id = r.course_id
      AND cs.section = r.section
      AND cs.semester_id = r.semester_id

    WHERE r.student_id = @studentId
      AND r.semester_id = @semesterId

    ORDER BY r.id DESC;
  '''),
          parameters: {
            'studentId': studentId,
            'semesterId': semesterId,
          },
        );
        final registeredCourses = result.map((row) {
          return {
            'id': row[0],
            'student_id': row[1],
            'course_id': row[2],
            'course_title': row[3],
            'section': row[4],
            'semester_id': row[5],
            'status': row[6],
            'day': row[7],
            'start_time': row[8]?.toString(),
            'end_time': row[9]?.toString(),
            'room': row[10],
          };
        }).toList();

        return Response.ok(
          jsonEncode({
            'student_id': studentId,
            'semester_id': semesterId,
            'registered_courses': registeredCourses,
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e, stack) {
        print('GET REGISTERED COURSES ERROR: $e\n$stack');

        return Response(
          500,
          body: jsonEncode({
            'error': e.toString(),
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });
    return router;
  }
}

void main() async {
  final server = CourseServer();
  await server.connectToDatabase();
  final handler =
      const Pipeline().addMiddleware(logRequests()).addHandler(server.router);
  await io.serve(handler, InternetAddress.anyIPv4, 8080);
  print('UniCouGuide Server running on port 8080');
}
