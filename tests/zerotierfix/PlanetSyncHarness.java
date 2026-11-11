import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import com.vnimy.zerotier.util.Constants;
import com.vnimy.zerotier.util.PlanetSyncer;

import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * PlanetSyncer 端到端验证：真实 HTTP 服务 + 真实生产代码（未见 Android API）。
 *
 * <p>编译并运行见同目录 run-planet-sync-test.sh。断言失败会以非零码退出。</p>
 */
public final class PlanetSyncHarness {

    private static int passed = 0;
    private static int failed = 0;

    /** 合法的假 planet：World 序列化格式 0x01 + 尾部填充 */
    private static byte[] fakePlanet(int size, int seed) {
        byte[] data = new byte[size];
        data[0] = (byte) PlanetSyncer.PLANET_TYPE;
        for (int i = 1; i < size; i++) {
            data[i] = (byte) ((i * 31 + seed) & 0xff);
        }
        return data;
    }

    public static void main(String[] args) throws Exception {
        File workDir = new File(args.length > 0 ? args[0] : "build/planet-sync-test");
        deleteRecursively(workDir);
        File filesDir = new File(workDir, "files");
        if (!filesDir.mkdirs()) {
            throw new IllegalStateException("cannot create " + filesDir);
        }
        // 与 App 内 PlanetSyncManager 完全相同的路径与文件名常量
        File dest = new File(filesDir, Constants.FILE_CUSTOM_PLANET);
        File temp = new File(filesDir, Constants.FILE_PLANET_TEMP);
        File backup = new File(filesDir, Constants.FILE_PLANET_BACKUP);

        // 官方内置 planet（1.12.2 node/Topology.cpp 的 ZT_DEFAULT_WORLD，570 字节，魔数 0x01）
        // 用于证明真实 planet 能通过客户端校验并被正确落盘
        File officialPlanet = new File(args.length > 1 ? args[1]
                : new File("real-planet-official.bin").getPath());
        byte[] realPlanet = Files.readAllBytes(officialPlanet.toPath());

        // 1.16.2 vendored mkworld 真实产物（276 字节，world_id=149604618，ts 新于内置 planet）
        File mkworldPlanet = new File(args.length > 2 ? args[2]
                : new File("planet-from-mkworld.bin").getPath());
        byte[] mkworldBytes = Files.readAllBytes(mkworldPlanet.toPath());

        byte[] planetV1 = fakePlanet(320, 1);
        byte[] planetV2 = fakePlanet(360, 2);

        AtomicInteger planetRequests = new AtomicInteger();
        AtomicInteger missingRequests = new AtomicInteger();
        AtomicInteger lastAuthHits = new AtomicInteger();
        String[] lastAuthorization = new String[1];

        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/planet", exchange -> {
            planetRequests.incrementAndGet();
            lastAuthorization[0] = exchange.getRequestHeaders().getFirst("Authorization");
            respond(exchange, 200, planetV1);
        });
        server.createContext("/planet-v2", exchange -> {
            planetRequests.incrementAndGet();
            respond(exchange, 200, planetV2);
        });
        server.createContext("/bad-magic", exchange -> {
            byte[] bad = fakePlanet(320, 3);
            bad[0] = 0x02;
            respond(exchange, 200, bad);
        });
        server.createContext("/real", exchange -> respond(exchange, 200, realPlanet));
        server.createContext("/mkworld", exchange -> respond(exchange, 200, mkworldBytes));
        server.createContext("/too-short", exchange -> respond(exchange, 200, new byte[]{0x01, 0x02}));
        server.createContext("/missing", exchange -> {
            missingRequests.incrementAndGet();
            respond(exchange, 404, "nope".getBytes(StandardCharsets.UTF_8));
        });
        server.createContext("/token", exchange -> {
            lastAuthorization[0] = exchange.getRequestHeaders().getFirst("Authorization");
            if (lastAuthorization[0] != null && lastAuthorization[0].contains("secret-token")) {
                lastAuthHits.incrementAndGet();
            }
            respond(exchange, 200, planetV1);
        });
        server.start();
        String base = "http://127.0.0.1:" + server.getAddress().getPort();
        try {
            // 1. 首次下载：落盘路径与内容
            PlanetSyncer.Result r1 = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/planet", "", "");
            check("首次下载成功", r1.success && r1.updated);
            check("落盘文件名 planet.custom", dest.isFile());
            check("落盘内容与服务器一致", Arrays.equals(Files.readAllBytes(dest.toPath()), planetV1));
            check("临时文件已清理", !temp.exists());
            check("sha256 与文件一致", PlanetSyncer.sha256Hex(dest).equals(r1.sha256));

            // 2. 第二次下载：内容替换 + 上一份备份
            PlanetSyncer.Result r2 = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/planet-v2", "", "");
            check("二次下载成功", r2.success);
            check("planet 已更新", Arrays.equals(Files.readAllBytes(dest.toPath()), planetV2));
            check("保留上一份 planet 备份", backup.isFile()
                    && Arrays.equals(Files.readAllBytes(backup.toPath()), planetV1));

            // 3. 魔数错误
            PlanetSyncer.Result r3 = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/bad-magic", "", "");
            check("魔数错误被拒绝", !r3.success);
            check("拒绝后 planet 未被破坏", Arrays.equals(Files.readAllBytes(dest.toPath()), planetV2));

            // 4. 长度不足
            PlanetSyncer.Result r4 = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/too-short", "", "");
            check("长度不足被拒绝", !r4.success);

            // 5. sha256 不匹配
            PlanetSyncer.Result r5 = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/planet", "",
                    "0000000000000000000000000000000000000000000000000000000000000000");
            check("sha256 不匹配被拒绝", !r5.success);
            // 6. sha256 匹配（大小写/分隔符容忍）
            File expectedFile = new File(workDir, "expected-planet");
            Files.write(expectedFile.toPath(), planetV1);
            String expectedSha = PlanetSyncer.sha256Hex(expectedFile);
            PlanetSyncer.Result r6 = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/planet", "", expectedSha.toUpperCase());
            check("sha256 匹配（大写）成功", r6.success);
            String colonSha = expectedSha.replaceAll("(.{2})", "$1:").toUpperCase();
            PlanetSyncer.Result r6b = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/planet", "", colonSha);
            check("sha256 匹配（冒号分隔）成功", r6b.success);

            // 7. HTTP 404 会重试且失败
            int before = missingRequests.get();
            PlanetSyncer.Result r7 = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/missing", "", "");
            check("404 失败", !r7.success);
            check("404 重试次数 = " + PlanetSyncer.MAX_ATTEMPTS,
                    missingRequests.get() - before == PlanetSyncer.MAX_ATTEMPTS);

            // 8. token 通过 Authorization 头下发
            PlanetSyncer.Result r8 = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/token", "secret-token", "");
            check("带 token 下载成功", r8.success);
            check("服务端收到 Bearer token", "Bearer secret-token".equals(lastAuthorization[0]));

            // 8.5 真实官方 planet：校验通过 + 正确落盘
            check("官方 planet 校验通过", PlanetSyncer.validatePlanetFile(officialPlanet) == null);
            PlanetSyncer.Result rReal = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/real", "", "");
            check("真实 planet 下载成功", rReal.success);
            check("真实 planet 内容一致",
                    Arrays.equals(Files.readAllBytes(dest.toPath()), realPlanet));

            // 8.6 1.16.2 mkworld 产物：客户端同样接受
            check("mkworld 产物校验通过", PlanetSyncer.validatePlanetFile(mkworldPlanet) == null);
            PlanetSyncer.Result rMk = PlanetSyncer.downloadAndInstall(
                    dest, temp, backup, base + "/mkworld", "", "");
            check("mkworld 产物下载成功", rMk.success);
            check("mkworld 产物内容一致",
                    Arrays.equals(Files.readAllBytes(dest.toPath()), mkworldBytes));

            // 9. 地址补全
            check("无协议头补 http", "http://1.2.3.4:3000/planet"
                    .equals(PlanetSyncer.normalizeUrl("1.2.3.4:3000/planet")));
            check("空地址保持不变", "".equals(PlanetSyncer.normalizeUrl("   ")));

            // 10. 校验函数对空文件/不存在文件的行为
            check("不存在的 planet 校验失败",
                    PlanetSyncer.validatePlanetFile(new File(filesDir, "nope")) != null);
            check("合法的 planet 校验通过", PlanetSyncer.validatePlanetFile(dest) == null);
        } finally {
            server.stop(0);
        }

        System.out.println("---------------------------------------------");
        System.out.println("PASS=" + passed + " FAIL=" + failed);
        if (failed > 0) {
            System.exit(1);
        }
    }

    private static void check(String name, boolean ok) {
        if (ok) {
            passed++;
            System.out.println("[PASS] " + name);
        } else {
            failed++;
            System.out.println("[FAIL] " + name);
        }
    }

    private static void respond(HttpExchange exchange, int code, byte[] body) throws IOException {
        exchange.getResponseHeaders().add("Content-Type", "application/octet-stream");
        exchange.sendResponseHeaders(code, body.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(body);
        }
        exchange.close();
    }

    private static void deleteRecursively(File file) {
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        file.delete();
    }
}
